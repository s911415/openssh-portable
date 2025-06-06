﻿If ($PSVersiontable.PSVersion.Major -le 2) {$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path}
Import-Module $PSScriptRoot\CommonUtils.psm1 -Force
#todo: -i -q -v -l -c -C
#todo: -S -F -V -e
$tC = 1
$tI = 0
$suite = "sshclient"

Describe "E2E scenarios for ssh client" -Tags "CI" {
    BeforeAll {
        if($OpenSSHTestInfo -eq $null)
        {
            Throw "`$OpenSSHTestInfo is null. Please run Set-OpenSSHTestEnvironment to set test environments."
        }

        $server = $OpenSSHTestInfo["Target"]
        $port = $OpenSSHTestInfo["Port"]
        $ssouser = $OpenSSHTestInfo["SSOUser"]

        $testDir = Join-Path $OpenSSHTestInfo["TestDataPath"] $suite
        if(-not (Test-Path $testDir))
        {
            $null = New-Item $testDir -ItemType directory -Force -ErrorAction SilentlyContinue
        }
        $acl = Get-Acl $testDir
        $rights = [System.Security.AccessControl.FileSystemRights]"Read, Write"
        $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($ssouser, $rights, "ContainerInherit,Objectinherit", "None", "Allow")
        $acl.SetAccessRule($accessRule)
        Set-Acl -Path $testDir -AclObject $acl
        #skip on ps 2 because non-interactive cmd require a ENTER before it returns on ps2
        $skip = $IsWindows -and ($PSVersionTable.PSVersion.Major -le 2)

        <#$testData = @(
            @{
                Title = 'Simple logon no option';
                LogonStr = "$($server.localAdminUserName)@$($server.MachineName)"
                Options = ""
            },
            @{
                Title = 'Simple logon using -C -l option'
                LogonStr = $server.MachineName
                Options = "-C -l $($server.localAdminUserName)"
            }
        )

        $testData1 = @(
            @{
                Title = "logon using -i -q option"
                LogonStr = "$($server.localAdminUserName)@$($server.MachineName)"
                Options = '-i $identifyFile -q'
            },
            @{
                Title = "logon using -i option"
                LogonStr = "$($server.localAdminUserName)@$($server.MachineName)"
                Options = '-i $identifyFile'
            },
            @{
                Title = "logon using -i -c  option"
                LogonStr = "$($server.localAdminUserName)@$($server.MachineName)"
                Options = '-i $identifyFile -c aes256-ctr'
            },
             -V does not redirect to file
            @{
                Title = "logon using -i -V option"
                LogonStr = "$($server.localAdminUserName)@$($server.MachineName)"
                Options = '-i $identifyFile -V'
                SkipVerification = $true
            },
            @{
                Title = 'logon using -i -l option'
                LogonStr = $server.MachineName
                Options = '-i $identifyFile -l $($server.localAdminUserName)'
            }
        )#>
        $dfltShellRegPath = "HKLM:\Software\OpenSSH"
        $dfltShellRegKeyName = "DefaultShell"
        $dfltShellCmdOptionRegKeyName = "DefaultShellCommandOption"
        Remove-ItemProperty -Path $dfltShellRegPath -Name $dfltShellRegKeyName -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $dfltShellRegPath -Name $dfltShellCmdOptionRegKeyName -ErrorAction SilentlyContinue

        function ConfigureDefaultShell {
            param
            (
                  [string] $default_shell_path,
                  [string] $default_shell_cmd_option_val = $null
            )

            if (!(Test-Path $dfltShellRegPath)) {
                New-Item -Path $dfltShellRegPath -Force | Out-Null
            }
            New-ItemProperty -Path $dfltShellRegPath -Name $dfltShellRegKeyName -Value $default_shell_path -PropertyType String -Force
            if ($default_shell_cmd_option_val -ne $null) {
                New-ItemProperty -Path $dfltShellRegPath -Name $dfltShellCmdOptionRegKeyName -Value $default_shell_cmd_option_val -PropertyType String -Force
            }
        }
    }

    BeforeEach {
        $stderrFile=Join-Path $testDir "$tC.$tI.stderr.txt"
        $stdoutFile=Join-Path $testDir "$tC.$tI.stdout.txt"
        $logFile = Join-Path $testDir "$tC.$tI.log.txt"
    }

    AfterEach {$tI++;}

   Context "$tC - Basic Scenarios" {

        BeforeAll {$tI=1}
        AfterAll{$tC++}

        It "$tC.$tI - test version" {
            iex "cmd /c `"ssh -V 2> $stderrFile`""
            $stderrFile | Should Contain "OpenSSH_for_Windows"
        }

        It "$tC.$tI - test help" {
            iex "cmd /c `"ssh -? 2> $stderrFile`""
            $stderrFile | Should Contain "usage: ssh"
        }

        It "$tC.$tI - remote echo command" {
            iex "$sshDefaultCmd echo 1234" | Should Be "1234"
        }

    }

    Context "$tC - exit code (exit-status.sh)" {
        BeforeAll {$tI=1}
        AfterAll{$tC++}

        It "$tC.$tI - various exit codes" {
            foreach ($i in (0,1,4,5,44)) {
                ssh -p $port $ssouser@$server exit $i
                $LASTEXITCODE | Should Be $i
            }
        }
    }

    Context "$tC - Redirection Scenarios" {

        BeforeAll {$tI=1}
        AfterAll{$tC++}

        It "$tC.$tI - stdout to file" -skip:$skip {
            ssh test_target powershell get-process > $stdoutFile
            $stdoutFile | Should Contain "ProcessName"
        }

        It "$tC.$tI - stdout to PS object" {
            $o = ssh test_target echo 1234
            $o | Should Be "1234"
        }

        It "$tC.$tI - multiple double quotes in cmdline" {
            # actual command line ssh target "cmd" /c "echo hello"
            $o = ssh test_target `"cmd`" /c `"echo hello`"
            $o | Should Be "hello"
        }

        It "$tC.$tI - stdin from PS object" -skip:$skip {
            # execute this script that dumps the length of input data, on the remote end
            $str = "begin {} process { Write-Output `$input.Length} end { }"
            $EncodedText =[Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($str))
            $h = "hello123"
            # ignore error stream using 2> $null
            $o = $h | ssh test_target PowerShell -NoProfile -NonInteractive -ExecutionPolicy Unrestricted -EncodedCommand $EncodedText 2> $null
            $o | Should Be "8"
        }

        It "$tC.$tI - stream file in and out" -skip:$skip {
            # prep a file of size > 10KB (https://github.com/PowerShell/Win32-OpenSSH/issues/908 was caught with such file size)
            $str = ""
            (1..100) | foreach {$str += "1234567890"}
            #strem file from local to remote
            $testsrc = Join-Path $testDir "$tC.$tI.testsrc"
            $testdst1 = Join-Path $testDir "$tC.$tI.testdst1"
            $null | Set-Content $testsrc
            $null | Set-Content $testdst1
            (1..105) | foreach {Add-Content -Encoding Ascii -Path $testsrc -Value $str}
            # execute this script that dumps input stream in target file, on the remote end
            $str = "begin {} process { Add-Content -Encoding Ascii -path $testdst1 -Value ([string]`$input)} end { }"
            $EncodedText =[Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($str))
            # ignore error stream using 2> $null
            get-content $testsrc | ssh test_target PowerShell -NoProfile -NonInteractive -ExecutionPolicy Unrestricted -EncodedCommand $EncodedText 2> $null
            (dir $testdst1).Length | Should Be (dir $testsrc).Length

            # stream file from remote to local
            $testdst2 = Join-Path $testDir "$tC.$tI.testdst2"
            $null | Set-Content $testdst2
            (ssh test_target powershell get-content $testdst1 -Encoding Ascii) | Set-Content $testdst2 -Encoding ASCII
            (dir $testdst2).Length | Should Be (dir $testsrc).Length

        }
    }

    Context "$tC - configure powershell default shell Scenarios" {
        BeforeAll {
            $tI=1
            $shell_path = (Get-Command powershell.exe -ErrorAction SilentlyContinue).path
            if($shell_path -ne $null) {
                ConfigureDefaultShell -default_shell_path $shell_path -default_shell_cmd_option_val "-c"
            }
        }
        AfterAll{
            $tC++
            Remove-ItemProperty -Path $dfltShellRegPath -Name $dfltShellRegKeyName -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $dfltShellRegPath -Name $dfltShellCmdOptionRegKeyName -ErrorAction SilentlyContinue
        }

        It "$tC.$tI - basic powershell" -skip:$skip {
            $o = ssh test_target Write-Output 1234
            $o | Should Be "1234"
        }

        It "$tC.$tI - basic in powershell cmdlet" -skip:$skip {
            $o = ssh test_target "cd `$env:ProgramFiles;pwd"
            $LASTEXITCODE | Should Be 0
            #$o | Should Match "c:\Program Files"
        }
        It "$tC.$tI - powershell as default shell and double quotes in cmdline" {
            # actual command line ssh target echo `"hello`"
            $o = ssh test_target echo `"hello`"
            $o | Should Be "hello"
        }
        It "$tC.$tI - multiple commands with double quotes in powershell cmdlet" -skip:$skip {
            # actual command line ssh target cd "$env:programfiles\";pwd
            $o = ssh test_target "cd `"`$env:programfiles\`";pwd"
            $LASTEXITCODE | Should Be 0
            $match = $o -match "Program Files"
            $match.count | Should be 1
        }
        It "$tC.$tI - multiple commands with double quotes in powershell cmdlet" -skip:$skip {
            # actual command line ssh target dir "$env:programfiles\";cd "$env:programfiles\";pwd
            $o = ssh test_target "dir `"`$env:programfiles\`";cd `"`$env:programfiles\`";pwd"
            $LASTEXITCODE | Should Be 0
            #$o -contains "Program Files" | Should Be $True
            $match = $o -match "Program Files"
            $match.count | Should Be 3
        }
        It "$tC.$tI - single quotes in powershell cmdlet" -skip:$skip {
            # actual command line ssh target echo '$env:computername'
            $o = ssh test_target "echo '`$env:computername'"
            $LASTEXITCODE | Should Be 0
            $o | Should Be `$env:computername
        }
    }

    Context "$tC - configure powershell as default shell with admin user" {
        BeforeAll {
            $tI=1
            $shell_path = (Get-Command powershell.exe -ErrorAction SilentlyContinue).path
            if ($shell_path -ne $null) {
                ConfigureDefaultShell -default_shell_path $shell_path -default_shell_cmd_option_val "-c"
            }
            $password = $OpenSSHTestInfo['TestAccountPW']
            Add-PasswordSetting -Pass $password
        }
        AfterAll {
            $tC++
            Remove-ItemProperty -Path $dfltShellRegPath -Name $dfltShellRegKeyName -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $dfltShellRegPath -Name $dfltShellCmdOptionRegKeyName -ErrorAction SilentlyContinue
            Remove-PasswordSetting
        }

        It "$tC.$tI - admin session can write to console" -skip:$skip {
            $adminusername = $OpenSSHTestInfo['AdminUser']
            $o = ssh $adminusername@test_target "Get-ComputerInfo"
            $LASTEXITCODE | Should Be 0 
            $o | Select-String -Pattern "WindowsVersion" | Should Match "WindowsVersion"
        }
    }

    Context "$tC - configure cmd as default shell" {
        BeforeAll {
            $tI=1
            $shell_path = (Get-Command cmd.exe -ErrorAction SilentlyContinue).path
            if($shell_path -ne $null) {
                ConfigureDefaultShell -default_shell_path $shell_path -default_shell_cmd_option_val "/c"
            }
        }
        AfterAll {
            $tC++
            Remove-ItemProperty -Path $dfltShellRegPath -Name $dfltShellRegKeyName -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $dfltShellRegPath -Name $dfltShellCmdOptionRegKeyName -ErrorAction SilentlyContinue
        }
        It "$tC.$tI - default shell as cmd" -skip:$skip {
            $o = ssh test_target where cmd
            $o | Should Contain "cmd"
        }
        It "$tC.$tI - cmd as default shell and double quotes in cmdline" {
            # actual command line ssh target echo "hello"
            $o = ssh test_target echo "`"hello`""
            $o | Should Be "`"hello`""
        }
        It "$tC.$tI - single quotes in powershell cmdlet" -skip:$skip {
            # actual command line ssh target echo '$env:computername'
            $o = ssh test_target "echo 'hello'"
            $LASTEXITCODE | Should Be 0
            $o | Should Be "'hello'"
        }
    }
    Context "$tC - configure ssh-shellhost as default shell" {
        BeforeAll {
            $tI=1
            $shell_path = (Get-Command ssh-shellhost -ErrorAction SilentlyContinue).path
            ConfigureDefaultShell -default_shell_path $shell_path
        }
        AfterAll{
            $tC++
            Remove-ItemProperty -Path $dfltShellRegPath -Name $dfltShellRegKeyName -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $dfltShellRegPath -Name $dfltShellCmdOptionRegKeyName -ErrorAction SilentlyContinue
        }
        It "$tC.$tI - shellhost as default shell and multiple double quotes in cmdline" {
            # actual command line ssh target "cmd" /c "echo "hello""
            $o = ssh test_target `"cmd`" /c `"echo `"hello`"`"
            $o | Should Be "`"hello`""
        }
    }

    Context "$tC - cmdline parameters" {
        BeforeAll {$tI=1}
        AfterAll{$tC++}

        It "$tC.$tI - verbose to file (-v -E)" {
            $o = ssh -v -E $logFile test_target echo 1234
            $o | Should Be "1234"
            #TODO - checks below are very inefficient (time taking).
            $logFile | Should Contain "OpenSSH_"
            $logFile | Should Contain "Exit Status 0"
        }


        It "$tC.$tI - cipher options (-c)" {
            #bad cipher
            iex "cmd /c `"ssh -c bad_cipher test_target echo 1234 2>$stderrFile`""
            $stderrFile | Should Contain "Unknown cipher type"
            #good cipher, ensure cipher is used from debug logs
            $o = ssh -c aes256-ctr  -v -E $logFile test_target echo 1234
            $o | Should Be "1234"
            $logFile | Should Contain "kex: server->client cipher: aes256-ctr"
            $logFile | Should Contain "kex: client->server cipher: aes256-ctr"
        }

        It "$tC.$tI - ssh_config (-F)" {
            #ensure -F is working by pointing to a bad configuration
            $badConfigFile = Join-Path $testDir "$tC.$tI.bad_ssh_config"
            "bad_config_line" | Set-Content $badConfigFile
            iex "cmd /c `"ssh -F $badConfigFile test_target echo 1234 2>$stderrFile`""
            $stderrFile | Should Contain "bad_ssh_config"
            $stderrFile | Should Contain "bad_config_line"
            $stderrFile | Should Contain "bad configuration options"

            #try with a proper configuration file. Put it on a unicode path with unicode content
            #so we can test the Unicode support simultaneously
            $goodConfigFile = Join-Path $testDir "$tC.$tI.Очень_хорошо_ssh_config"
            "#this is a Unicode comment because it contains русский язык" | Set-Content $goodConfigFile -Encoding UTF8
            "Host myhost" | Add-Content $goodConfigFile
            "    HostName $server" | Add-Content $goodConfigFile
            "    Port $port" | Add-Content $goodConfigFile
            "    User $ssouser" | Add-Content $goodConfigFile
            $o = ssh -F $goodConfigFile myhost echo 1234
            $o | Should Be "1234"
        }

        It "$tC.$tI - IP options - (-4) (-6)" {
            # TODO - this test assumes target is localhost.
            # make it work independent of target
            #-4
            $o = ssh -4 -v -E $logFile test_target echo 1234
            $o | Should Be "1234"
            $logFile | Should Contain "[127.0.0.1]"
            #-4
            $o = ssh -6 -v -E $logFile test_target echo 1234
            $o | Should Be "1234"
            $logFile | Should Contain "[::1]"
        }

        It "$tC.$tI - tilde expand for path with forward slash" {
            $o = ssh -v -i ~/test/key/path -E $logFile test_target echo 1234
            $o | Should Be "1234"
            $logFile | Should Not Contain "tilde_expand: No such user"
        }

        It "$tC.$tI - tilde expand for path with backslash" {
            $o = ssh -v -i ~\test\key\path -E $logFile test_target echo 1234
            $o | Should Be "1234"
            $logFile | Should Not Contain "tilde_expand: No such user"
        }

        It "$tC.$tI - auto populate known hosts" {

            $kh = Join-Path $testDir "$tC.$tI.known_hosts"
            $nul | Set-Content $kh
            # doing via cmd to intercept and drain stderr output
            iex "cmd /c `"ssh -o UserKnownHostsFile=`"$kh`" -o StrictHostKeyChecking=no test_target hostname 2>&1`""
            @(Get-Content $kh).Count | Should Be 1
        }

        It "$tC.$tI - ProxyCommand with file name only" {
            iex "cmd /c `"ssh -o ProxyCommand=`"`"cmd.exe /c echo test string for invalid proxy 1>&2`"`" abc 2>$stderrFile`""
            $stderrFile | Should Contain "test string for invalid proxy"
        }

        It "$tC.$tI - ProxyCommand with absolute path to the file" {
            iex "cmd /c `"ssh -o ProxyCommand=`"`"$($env:ComSpec) /c echo test string for invalid proxy 1>&2`"`" abc 2>$stderrFile`""
            $stderrFile | Should Contain "test string for invalid proxy"
        }
    }
}
