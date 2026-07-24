#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the shared effectful shims in lib/Common.ps1 (dot-sourced).
    Write-BootstrapLog is a thin Write-Information wrapper exercised by every
    bootstrap run; the temp-file lifecycle in Invoke-WithBodyFile is the seam
    worth pinning here.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Common.ps1')
}

Describe 'Invoke-WithBodyFile' {
    It 'runs the action with an existing temp file that holds the body' {
        $result = Invoke-WithBodyFile -Body 'payload-123' -Action {
            param($path)
            [pscustomobject]@{
                Exists  = Test-Path -LiteralPath $path
                Content = [System.IO.File]::ReadAllText($path)
            }
        }
        $result.Exists  | Should -BeTrue
        $result.Content | Should -Be 'payload-123'
    }
    It 'removes the temp file after the action returns' {
        $box = @{ path = $null }
        Invoke-WithBodyFile -Body 'x' -Action { param($p) $box.path = $p }
        Test-Path -LiteralPath $box.path | Should -BeFalse
    }
    It 'removes the temp file even when the action throws' {
        $box = @{ path = $null }
        { Invoke-WithBodyFile -Body 'x' -Action { param($p) $box.path = $p; throw 'boom' } } |
            Should -Throw -ExpectedMessage '*boom*'
        Test-Path -LiteralPath $box.path | Should -BeFalse
    }
    It 'propagates the action output to the caller' {
        $out = Invoke-WithBodyFile -Body 'x' -Action { 'action-result' }
        $out | Should -Be 'action-result'
    }
}
