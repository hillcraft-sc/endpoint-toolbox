$desktop = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force

Describe 'Saved remote command catalog' {
    It 'loads all 29 starter commands as unique friendly names and valid PowerShell without executing them' {
        & (Get-Module EndpointToolboxUI) {
            $commands = @(Get-EndpointRemoteCommands)
            $commands.Count | Should Be 29
            @($commands.Name | Sort-Object -Unique).Count | Should Be 29
            foreach ($command in $commands) {
                [string]::IsNullOrWhiteSpace($command.Description) | Should Be $false
                $tokens = $null; $errors = $null
                $null = [Management.Automation.Language.Parser]::ParseInput($command.Command, [ref]$tokens, [ref]$errors)
                $errors.Count | Should Be 0
            }
            ($commands | Where-Object Name -eq 'System - Windows version and build').Command | Should Match '\$cv.DisplayVersion'
            ($commands | Where-Object Name -eq 'Upgrade - Remove failed upgrade staging files').Command | Should Match ([regex]::Escape("'C:\`$WINDOWS.~BT'"))
        }
    }
    It 'blocks both profile templates until the retained profile is explicitly edited' {
        & (Get-Module EndpointToolboxUI) {
            function Get-CimInstance { throw 'Profile lookup must not run with the placeholder unchanged.' }
            foreach ($command in @(Get-EndpointRemoteCommands | Where-Object Name -like 'Profiles -*')) {
                $message = ''
                try { & ([scriptblock]::Create($command.Command)) }
                catch { $message = $_.Exception.Message }
                $message | Should Match 'Set keepProfileFolder'
                $command.Command | Should Not Match 'exampleuser'
                $command.Command | Should Match '-not \$_.Loaded'
            }
        }
    }
    It 'rejects malformed, incomplete, duplicate, unsupported and syntactically invalid catalogs' {
        & (Get-Module EndpointToolboxUI) {
            $path = Join-Path $env:TEMP "EndpointToolbox-command-tests-$([guid]::NewGuid()).json"
            try {
                $cases = @(
                    '{'
                    '{"SchemaVersion":2,"Commands":[]}'
                    '{"SchemaVersion":1,"Commands":[]}'
                    '{"SchemaVersion":1,"Commands":[{"Name":"Missing command","Description":"Fixture"}]}'
                    '{"SchemaVersion":1,"Commands":[{"Name":"Bad syntax","Description":"Fixture","Command":"if ("}]}'
                    '{"SchemaVersion":1,"Commands":[{"Name":"Same","Description":"Fixture","Command":"1"},{"Name":"same","Description":"Fixture","Command":"2"}]}'
                )
                foreach ($json in $cases) {
                    Set-Content -LiteralPath $path -Value $json
                    $rejected = $false
                    try { $null = @(Get-EndpointRemoteCommands -Path $path) } catch { $rejected = $true }
                    $rejected | Should Be $true
                }
                Remove-Item -LiteralPath $path
                $rejected = $false
                try { $null = @(Get-EndpointRemoteCommands -Path $path) } catch { $rejected = $true }
                $rejected | Should Be $true
            }
            finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
        }
    }
    It 'keeps the named, loaded and special profiles out of removal and rejects an unknown retained profile' {
        & (Get-Module EndpointToolboxUI) {
            $removed = [Collections.Generic.List[string]]::new()
            function Get-CimInstance {
                @(
                    [pscustomobject]@{LocalPath='C:\Users\KeepUser';Loaded=$false;Special=$false}
                    [pscustomobject]@{LocalPath='C:\Users\ActiveUser';Loaded=$true;Special=$false}
                    [pscustomobject]@{LocalPath='C:\Windows\System32\config\systemprofile';Loaded=$false;Special=$true}
                    [pscustomobject]@{LocalPath='C:\Users\UnusedUser';Loaded=$false;Special=$false}
                )
            }
            function Remove-CimInstance {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline)]$InputObject)
                process { $removed.Add($InputObject.LocalPath) }
            }
            $command = (Get-EndpointRemoteCommands | Where-Object Name -eq 'Profiles - Remove unused profiles (edit first)').Command
            & ([scriptblock]::Create($command.Replace("`$keepProfileFolder = 'REPLACE_WITH_PROFILE_FOLDER'", "`$keepProfileFolder = 'KeepUser'")))
            $removed.Count | Should Be 1
            $removed[0] | Should Be 'C:\Users\UnusedUser'
            $removed.Clear()
            $message = ''
            try { & ([scriptblock]::Create($command.Replace("`$keepProfileFolder = 'REPLACE_WITH_PROFILE_FOLDER'", "`$keepProfileFolder = 'UnknownUser'"))) }
            catch { $message = $_.Exception.Message }
            $message | Should Match 'profile folder to retain was not found'
            $removed.Count | Should Be 0
        }
    }
    It 'loads command text literally rather than interpolating or executing it locally' {
        & (Get-Module EndpointToolboxUI) {
            $path = Join-Path $env:TEMP "EndpointToolbox-literal-tests-$([guid]::NewGuid()).json"
            try {
                $literal = 'throw "This must never execute during catalog loading: $env:COMPUTERNAME"'
                @{SchemaVersion=1;Commands=@(@{Name='Literal fixture';Description='Fixture';Command=$literal})} |
                    ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $path
                $commands = @(Get-EndpointRemoteCommands -Path $path)
                $commands.Count | Should Be 1
                $commands[0].Command | Should Be $literal
            }
            finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
        }
    }
}
