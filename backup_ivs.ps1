<#
.SYNOPSIS
Script to scrape IVS VALT video servers

.DESCRIPTION
Fetches list of recordings with the IVS VALT API
Creates folder structure
Writes metadata to a file

.PARAMETER production
Switch, Actually download files

.PARAMETER metadataonly
Switch, Don't waste time running rsync, just grab
metadata of the recordings

.PARAMETER noisy
Switch, Show debug messages

.EXAMPLE
.\backupivs.ps1 -config .\settings.json -production
#>
param (
    # Config json path
    [Parameter(Mandatory = $false)]
    [string]$conf = "",

    # Are we in Prod?
    [Parameter(Mandatory = $false)]
    [switch]$production,

    # Don't even run rsync?
    [Parameter(Mandatory = $false)]
    [switch]$metadataonly,

    # Do we want a noisy terminal
    [Parameter(Mandatory = $false)]
    [switch]$noisy
)

#region: Variables
# Globals
$valtversionmin = @(5, 0, 0) # Minimum version of IVS VALT we support
$valtversionmax = @(6, 999, 0) # Maximum version of IVS VALT we support
$authoryear = "Kieran Gee 2023 - 2025"
$global:errorlist = @()
# valt_recording/video folder, this should never change
$rsyncremotedir = "/usr/local/valt/docker/wowza/content/records/video/"
# Run rsync in test mode, do not actually download video files

$runningonwindows = $PSVersionTable.PSVersion.Major -ge 6 -and $PSVersionTable.Platform -eq "Win32NT"

$rsyncexecutable = ".\rsync\rsync.exe"
$sshexecutable = ".\rsync\ssh.exe"
$sshkeypath = ".\rsync\id_ed25519"
if (! $runningonwindows) {
    $rsyncexecutable = "rsync"
    $sshexecutable = "ssh"
    $sshkeypath = "~/.ssh/id_ed25519_ivs"
}

$rsynccommandprefix = "$rsyncexecutable -rnvP --size-only -e `"$sshexecutable -i $sshkeypath  -o StrictHostKeyChecking=no`" --rsync-path=`"sudo /usr/bin/rsync`""
if ($production) {
    # Actually download video files command
    $rsynccommandprefix = "$rsyncexecutable -rvP --size-only -e `"$sshexecutable -i $sshkeypath -o StrictHostKeyChecking=no`"--rsync-path=`"sudo /usr/bin/rsync`""
}

# Builtin Powershell vars
$ErrorActionPreference = "Stop"
if ($noisy) {
    $DebugPreference = "Continue"
}
#endregion

#region Helper Functions
# Get the api token
function Get-Token {
    param(
        [Parameter(Mandatory)]
        [string]$fqdn,

        [Parameter(Mandatory)]
        [string]$username,

        [Parameter(Mandatory)]
        [string]$pw
    )

    $apicreds = @{
        "username" = $username
        "password" = $pw
    }
    $jsonBody = $apicreds | ConvertTo-Json

    $url = "http://" + $fqdn + "/api/v3/login"

    $response = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -Body $jsonBody

    $token = $response.data.access_token
    Write-Debug ("Token: " + $token)

    return $token
}

# Generic function to send IVS API calls
function Send-PostRequest {
    param(
        [Parameter(Mandatory)]
        [string]$url,

        [Parameter(Mandatory)]
        [string]$token,

        [object]$body = "{}"
    )

    Write-Debug ("[Send-PostRequest] URL: " + $url + "?access_token=<token>")
    $url = $url + "?access_token=" + $token

    $response = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -Body $body

    return $response
}

function Send-GetRequest {
    param(
        [Parameter(Mandatory)]
        [string]$url,

        [Parameter(Mandatory)]
        [string]$token

    )

    Write-Debug ("[Send-GetRequest] URL: " + $url + "?access_token=<token>")
    $url = $url + "?access_token=" + $token

    $response = Invoke-RestMethod -Method Get -Uri $url

    return $response
}

function Confirm-ValidValtVersion {
    param (
        [Parameter(Mandatory)]
        [string]$fqdn,

        [Parameter(Mandatory)]
        [string]$token
    )

    $url = "http://" + $fqdn + "/api/v3/admin/general"
    $response = Send-GetRequest -url $url -token $token # We don't need a token for this endpoint

    Write-Host ("VALT Version: " + $response.data.version)

    # Split the version string into an array of integers
    $versionbeforespace = $response.data.version -split ' '
    if ($versionbeforespace.Count -gt 1) {
        # If there is a space, we only want the first part
        $version = $versionbeforespace[0]
    }
    else {
        $version = $response.data.version
    }

    $versionParts = $version -split '\.'
    $versionArray = @()
    foreach ($part in $versionParts) {
        $versionArray += [int]$part
    }

    $spiel = "check for other versions of this script, or upgrade your VALT appliance."
    # Check that we are above the minimum version
    foreach ($i in 0..($valtversionmin.Count - 1)) {
        if ($versionArray[$i] -lt $valtversionmin[$i]) {
            $spiel = ("VALT Version: " + $version + " is below the min version: " + ($valtversionmin -join '.'))
            Write-Host ($spiel)
            throw $spiel
        }
        elseif ($versionArray[$i] -gt $valtversionmin[$i]) {
            break
        }
    }
    # Check that we are below the maximum version
    foreach ($i in 0..($valtversionmax.Count - 1)) {
        if ($versionArray[$i] -gt $valtversionmax[$i]) {
            $spiel = ("VALT Version: " + $version + " is above the max version: " + ($valtversionmax -join '.'))
            Write-Host ($spiel)
            throw $spiel
        }
        elseif ($versionArray[$i] -lt $valtversionmax[$i]) {
            break
        }
    }
}

# Mount Drive
function New-TempMappedDrive {
    param (
        # Drive letter for the mount
        [Parameter(Mandatory)]
        [string]$mydriveletter,

        # CIFS Share, use Windows format \\path\to\share
        [Parameter(Mandatory)]
        [string]$mycifspath
    )

    $mydrivepath = ($mydriveletter + ":")

    $driveexists = Test-Path $mydrivepath
    if ($driveexists) {
        Write-Output ("Drive: " + $mydriveletter + " mounted, trusting...")
    }
    else {
        Write-Output ("Mounting: " + $mycifspath + " to: " + $mydriveletter)
        New-PSDrive -Name $mydriveletter -Root $mycifspath -Persist -Scope Script -PSProvider "FileSystem" -ErrorAction Stop
    }
}

# Convert date Unix Epoch time (from database) to ISO8601 date
function Convert-EpochToISO8601 {
    param (
        [Parameter(Mandatory)]
        [long]$epochTime
    )

    # Convert Epoch time to a DateTime object
    $dateTime = [System.DateTimeOffset]::FromUnixTimeSeconds($epochTime)

    # Format the DateTime object to ISO 8601 format
    $iso8601 = $dateTime.ToString("yyyy-MM-dd")

    return $iso8601
}

# Convert the supplied windows path to a path that works within cygwin apps
function Convert-WindowsPathToCygdrivePath {
    param (
        [Parameter(Mandatory)]
        [string]$thepath
    )
    $thepath = $thepath.Replace('\', '/')
    if ($thepath[1] -eq ":") {
        # If we are given and absolute path (includes drive letter) we need to convert it
        if ($thepath.Length -eq 2) {
            $thepath = $thepath + '/'
        }
        $thepath = $thepath.Replace(':', '')
        $thepath = "/cygdrive/" + $thepath

    }
    return $thepath
}

# Build and return the string that will be the entries metadata
function Set-Metadata {
    # This is here to be potentially expanded
    param (
        [Parameter(Mandatory)]
        [object]$item
    )
    return $item | ConvertTo-Json
}

function Close-Script {
    $exitcode = 0
    $resultslogpath = Join-Path -Path $config.outputpath -ChildPath lastrunsummery.log
    Write-Host("================================================================================")
    Write-Host("Ending Transcript on main, writing results to: " + $resultslogpath )
    Stop-Transcript # Very important, otherwise it will log the password
    Start-Transcript -Path $resultslogpath

    Write-Host("Script executed from host: " + $env:computername)
    Write-Host("Script execution start time: " + $startTime)
    Write-Host("Script execution end time: " + (Get-Date))
    Write-Host("Script execution time: " + ((Get-Date) - $startTime))

    if ($global:errorlist.Count -ne 0) {
        $exitcode = 1
        Write-Host("Some errors did occur:")
        foreach ($item in $global:errorlist) {
            Write-Host($item) -ForegroundColor "Red" -BackgroundColor "Black"
        }
    }
    Write-Host("Done")

    Stop-Transcript # Very important, otherwise it will log the password
    Exit $exitcode # Needed since the timeout check calls this function
}
#endregion

#region: Get-Videos
function Get-Videos {
    param (
        [Parameter(Mandatory)]
        [object]$site,

        [Parameter(Mandatory)]
        [object]$sitefolderpath,

        [Parameter(Mandatory)]
        [object]$responserecords,

        [Parameter(Mandatory)]
        [object]$responseusers
    )

    # For ever record, we make the folders, grab metadata from the api, download files
    # Write-Host ($response.data.records | Format-Table | Out-String )
    foreach ($record in $responserecords.data.records) {
        # Check if this script has run for too long
        $elapsedTime = (Get-Date) - $startTime
        if (($config.timeouthours -ne 0) -and ($elapsedTime.TotalHours -gt $config.timeouthours)) {
            Write-Host("Script has run for over " + $config.timeouthours + " hours, exiting")
            Close-Script
        }

        Write-Host("--------------------------------------------------------------------------------")
        Write-Host("Processing Record: " + $record.id + " " + $record.name) -ForegroundColor "Black" -BackgroundColor "White"

        # Get the team name
        $userinfo = $responseusers.data | Where-Object { $_.id -eq $record.author.id }
        $team = $userinfo.user_group.name

        Write-Host("Recording User: " + $record.author.name + ", Team: " + $team) -ForegroundColor "Black" -BackgroundColor "White"

        # Path of the team
        $siteteamfolderpath = Join-Path -Path $sitefolderpath -ChildPath $team

        # Get date from record
        $iso8601date = Convert-EpochToISO8601 -epochTime $record.created
        $year = $iso8601date.substring(0, 4)

        # Cleanup File Name
        foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
            $record.name = $record.name.Replace($char, "-")
        }

        # Ensure folder for the year has been created
        $basefolderpath = Join-Path -Path $siteteamfolderpath -ChildPath $year
        if (!(Test-Path -Path $basefolderpath -PathType Container)) {
            New-Item -Path $siteteamfolderpath -Name $year -ItemType "directory"
            Write-Host("Created path: " + $basefolderpath) -ForegroundColor "Black" -BackgroundColor "White"
        }

        # If we have a legacy folder, skip
        $escapedRecordName = [regex]::Escape($record.name)
        $legacyPattern = "^$iso8601date\s\d+\s$escapedRecordName$"
        $legacyFolders = Get-ChildItem -Path $basefolderpath -Directory | Where-Object { $_.Name -match $legacyPattern }
        Write-Debug("Checking for legacy folders with pattern: " + $legacyPattern)
        if ($legacyFolders.Count -gt 0) {
            Write-Host("Found legacy folder(s), skipping record: $($record.id) $($record.name)") -ForegroundColor "Red" -BackgroundColor "Black"
            foreach ($folder in $legacyFolders) {
                Write-Host("Skipping old folder: $($folder.Name)") -ForegroundColor "Red" -BackgroundColor "Black"
            }
            continue
        }

        # We have a record that isn't legacy, continue with processing
        $recordfoldername = $iso8601date + " " + $record.id + " " + $record.name
        Write-Debug ("No legacy folder found, continuing with record " + $recordfoldername)
        # Create desired folder path for record
        $folderpath = Join-Path -Path $basefolderpath -ChildPath $recordfoldername

        # Check if there already is a folder for this ID, rename it if it doesnt match the ID in the database
        # I hate this but it works, coudldnt get a shorthand version working
        $folderlist = Get-ChildItem -Path $basefolderpath -Directory
        foreach ($folder in $folderlist) {
            # I understand this next block is heck, but I couldn't get it running any other way
            $folderrecordnumber = $folder.Name -split " "
            $folderrecordnumber = $folderrecordnumber[1]
            # $folderrecordnumber = [int]$folderrecordnumber
            # $recordidint = [int]$record.id

            # Do the normal logic
            if (($folderrecordnumber -eq $record.id) -and ($recordfoldername -ne $folder.Name)) {
                Write-Debug($folderrecordnumber.ToString() + " and " + $record.id.ToString())
                Write-Debug($recordfoldername + " and " + $folder.Name)
                Write-Host("Rename folder: `"" + $basefolderpath + "`\" + $folder.Name + "`" to `"" + $basefolderpath + "`\" + $recordfoldername + "`"") -ForegroundColor "Black" -BackgroundColor "White"
                Move-Item -Path (Join-Path -Path $basefolderpath -ChildPath $folder.Name) -Destination (Join-Path -Path $basefolderpath -ChildPath $recordfoldername) -Force
            }
        }

        Write-Debug("Desired folder path  : " + $folderpath)
        Write-Debug("What will be created : " + (Join-Path -Path $basefolderpath -ChildPath $recordfoldername))

        # Create path if it doesnt exist, doesnt rely on the rename logic since I might remove it
        if (!(Test-Path -Path $folderpath -PathType Container)) {
            New-Item -Path $basefolderpath -Name $recordfoldername -ItemType "directory"
            Write-Debug("Created path: " + $folderpath)
        }

        # Write json entry to metadate file
        $metadata = Set-Metadata($record)
        $metadatafilepath = Join-Path -Path $folderpath -ChildPath "metadata.txt"
        if (!(Test-Path -Path $metadatafilepath -PathType Leaf)) {
            New-Item -Path $metadatafilepath -ItemType File
            Write-Debug("Created item: " + $metadatafilepath)
        }
        Write-Host("Writing metadata: " + $metadatafilepath) -ForegroundColor "Black" -BackgroundColor "White"
        Set-Content -Path $metadatafilepath -Value $metadata

        # Run the Rsync Command
        if (-not $metadataonly) {
            Write-Host("Syncing: " + $site.fqdn + ":" + $rsyncremotedir + $record.id + "/ -> " + $folderpath) -ForegroundColor "Black" -BackgroundColor "White"
            # First we convert the folder path to a path that cygwin (cygpath aware apps) will understand
            $rsyncfolderpath = Convert-WindowsPathToCygdrivePath($folderpath)
            # Build and rsync command
            # To make the rsync command less noisy we need to redirect stderr
            # cygwin/msys2 rsync will have errors every time since ~/.ssh not being writable
            # For whatever reason, if you redirect stderr to $null and ErrorActionPreference is "Stop" the program will stop
            # But not if it you don't redirect stderr 🤷‍♂️
            $rsynccommand = $rsynccommandprefix + " ivsadmin@" + $site.fqdn + ":" + $rsyncremotedir + $record.id + "/ `"" + $rsyncfolderpath + "`""
            if (-not $noisy) {
                $ErrorActionPreference = "Continue"
                $rsynccommand = $rsynccommand + " 2>`$null"
            }

            # Get camera count of the recording and filecounts from folder to see if we want to download
            $ncameras = ($record.cameras.PSObject.Properties.count).count # Powershell users hate him
            $mp4Files = Get-ChildItem -Path $folderPath -Filter "*$($record.id)*.mp4"
            $jpegFiles = Get-ChildItem -Path $folderPath -Filter "*$($record.id)*.jpeg"
            Write-Debug("`$mp4Files matching " + "*$($record.id)*.mp4" + " : " + $mp4Files)
            Write-Debug("n matching mp4 files: " + $mp4Files.Count + ", n cameras: " + $ncameras + " `| " + "n jpegs: " + $jpegFiles.Count)
            if (($mp4Files.Count -lt $ncameras) -and ($jpegFiles.Count -lt 1)) {
                Write-Debug $rsynccommand
                Write-Host("Running rsync... `$production: " + $production) -ForegroundColor "Black" -BackgroundColor "White"
                $rsyncexpression = Invoke-Expression $rsynccommand
                Write-Host ($rsyncexpression | Format-List | Out-String)
                $ErrorActionPreference = "Stop"
            }
            else {
                Write-Host("Not going to run rsync as filecount looks good")
            }
        }
        else {
            Write-Host("Not running rsync. `$metadataonly: " + $metadataonly)
        }

        # Set the permissions to all the files in this folder since cygwin rsync does some weird permissions things
        # And a fun regex, Delete rsync files temp files that may get left behind if the script crashes
        # Use the metadata file as the base for ACLs since it was created properly outside of rsync
        $filelist = Get-ChildItem -Path $folderpath -File
        foreach ($file in $fileList) {
            if ($file.Name -match '^\..*\..{3,4}\..{6}$') {
                # startline, whatever, dot, 3 or 4 letter file extension, dot 6 characters, end
                Write-Host("Removing partial file: " + $file.FullName) -ForegroundColor "Black" -BackgroundColor "White"
                Remove-Item -Path $file.FullName
            }
        }
        Write-Host(" ") # We are done with this record!
    }
    Write-Host("Done with site: " + $site.sitename)
}
#endregion

# "Main"
function Start-ProcessingSites {
    $sites = $config.sites
    $out = $config.outputpath

    foreach ($site in $sites) {
        Write-Host("================================================================================")
        Write-Host("Site: " + $site.sitename)
        Write-Host("Server: " + $site.fqdn)
        # Create folder for site
        $sitefolderpath = Join-Path -Path $out -ChildPath $site.sitename
        if (!(Test-Path -Path $sitefolderpath -PathType Container)) {
            New-Item -Path $out -Name $site.sitename -ItemType "directory"
            Write-Host("Created path: " + $sitefolderpath) -ForegroundColor "Black" -BackgroundColor "White"
        }

        Write-Host("-=-=-=-=--=-=-=-=--=-=-=-=--=-=-=-=--=-=-=-=--=-=-=-=--=-=-=-=--=-=-=-=--=-=-=-=-")
        Write-Host("API User: " + $site.user)

        $actuallyproces = $false
        try {
            # Get token for this user (users are per site), each user has access to one groups data
            $token = Get-Token -username $site.user -pw $site.password -fqdn $site.fqdn
            Write-Host("Got Token!")
            Confirm-ValidValtVersion $site.fqdn $token
            # Records
            $url = "http://" + $site.fqdn + "/api/v3/records"
            $responserecords = Send-PostRequest -url $url -token $token
            Write-Host("Got List of recordings!")
            # Write-Host($responserecords.data.records | Format-Table | Out-String)

            # Users
            $url = "http://" + $site.fqdn + "/api/v3/admin/users"
            $responseusers = Send-GetRequest -url $url -token $token
            Write-Host("Got List of recordings!")

            $actuallyproces = $true
        }
        catch {
            $currenterrormessage = "Issue getting token or recordings, user: " + $site.user + " site: " + $site.fqdn + " " + $_
            $global:errorlist += $currenterrormessage
            Write-Host($currenterrormessage) -ForegroundColor "Red" -BackgroundColor "Black"
        }

        # I couldnt get powershell to break from only one layer of the loop
        # and I didn't want to have this in the try/catch for hopefully obvious reasons
        # Which is why we are doing it like this
        if ($actuallyproces) {
            # This is where the magic happens
            Get-Videos -site $site -sitefolderpath $sitefolderpath -responserecords $responserecords -responseusers $responseusers
        }
    }
}
#endregion

#region Start
# Log Output
try { Stop-Transcript } catch {} # Only useful when running adhoc and you had to ctrl-c it, will hang otherwises
while ($true) {
    try {
        Write-Host("Trying to remove old log...")
        Remove-Item -Path $(Join-Path -Path $PSScriptRoot -ChildPath "lastrun.log") -Force
        break
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        # GOD DAMN MICROSOFT HOW WAS I SUPPOSED TO FIND THIS WITHOUT GOOGLE, FOR THE LOVE OF GOD PUT IT IN THE ACTUAL ERROR THAT SHOWS UP IN MY TERMINAL OH MY GOD AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        break
    }
    catch {
        Write-Host($_)
    }
    Start-Sleep -Seconds 1
}
Start-Transcript -Path $(Join-Path -Path $PSScriptRoot -ChildPath "lastrun.log")

# Time the execution
$startTime = Get-Date

Write-Host("backup_ivs.ps1 " + $authoryear)
Write-Host("Started: " + $(Get-Date))

# Print args provided
Write-Host("conf: " + $conf)
Write-Host("production: " + $production)
Write-Host("metadataonly: " + $metadataonly)
Write-Host("noisy: " + $noisy)

# Load config
if ($conf -eq "") {
    Write-Host ("No config specified, using default location")
    $conf = $(Join-Path -Path $PSScriptRoot -ChildPath "settings.json")
}
Write-Host("Loading Configuration from: " + $conf)
$config = Get-Content -Raw -Path $conf | ConvertFrom-Json

if (($config.shareddiveletter -ne "") -and ($config.sharedfolderpath -ne "")) {
    Write-Host ("Shared drive letter and sharedfolder path spefified, mounting")
    New-TempMappedDrive -mydriveletter $config.shareddiveletter -mycifspath $config.sharedfolderpath
}

# Start the main loop, do in a try catch since otherwise if it crashed it would log the password
try {
    Start-ProcessingSites
}
catch {
    $global:errorlist += "Unhandled error in Start-ProcessingSites: " + $_
}

Close-Script
#endregion
