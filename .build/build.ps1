[CmdletBinding()]
param(
    [string] $Configuration = 'Release',
    [string] $BranchName = 'dev',
    [bool] $IsDefaultBranch = $false,
    [string] $NugetFeedUrl,
    [string] $NugetFeedApiKey
)

$RootDir = "$PsScriptRoot\.." | Resolve-Path
$OutputDir = "$RootDir\.output\$Configuration"
$LogsDir = "$OutputDir\logs"
$NugetPackageOutputDir = "$OutputDir\nugetpackages"
$Solution = 'TODO: <path to the solution file>'
# We probably don't want to publish every single nuget package ever built to our external feed.
# Let's only publish packages built from the default branch (master) by default.
# packages built from non master branches would still be available using the built-in Teamcity feed at
# http://<teamcity-server>/guestAuth/app/nuget/v1/FeedService.svc/
# or http://<teamcity-server>/httpAuth/app/nuget/v1/FeedService.svc/
$PublishNugetPackages = $env:TEAMCITY_VERSION -and $IsDefaultBranch
$NugetExe = "$PSScriptRoot\packages\Nuget.CommandLine\tools\Nuget.exe" | Resolve-Path

task CreateFolders {
    New-Item $OutputDir -ItemType Directory -Force | Out-Null
    New-Item $LogsDir -ItemType Directory -Force | Out-Null
    New-Item $NugetPackageOutputDir -ItemType Directory -Force | Out-Null
}

# Retrieves the first Major.Minor line in $RootDir\RELEASENOTES.md as the $Version, appends
# all subsequent lines in the file as $Content.
function Get-ReleaseNotes {
    $ReleaseNotesPath = "$RootDir\RELEASENOTES.md" | Resolve-Path
    $Lines = [System.IO.File]::ReadAllLines($ReleaseNotesPath, [System.Text.Encoding]::UTF8)
    $Result = @()
    $Version = $Null
    $Lines | ForEach-Object {
        $Line = $_.Trim()
        if (-not $Version) {
            $Match = [regex]::Match($Line, '[0-9]+\.[0-9]+')
            if ($Match.Success) {
                $Version = $Match.Value
            }
        }
        if ($Version) {
            $Result += $Line
        }
    }
    if (-not $Version) {
        throw "Failed to parse release notes: $ReleaseNotesPath"
    }
    return @{
        Content = $Result -join [System.Environment]::NewLine
        Version = [version] $Version
    }
}

# Synopsis: Retrieve two part semantic version information and release notes from $RootDir\RELEASENOTES.md
# $script:AssemblyVersion = Major.0.0.0
# $script:AssemblyFileVersion = Major.Minor.$VersionSuffix.0
# $script:NugetPackageVersion = Major.Minor.$VersionSuffix or Major.Minor.$VersionSuffix-branch
# $script:ReleaseNotes = read from RELEASENOTES.md
function GenerateSemVerInformationFromReleaseNotesMd([int] $VersionSuffix) {
    $Notes = Get-ReleaseNotes
    $script:SemanticVersion = [System.Version] "$($Notes.Version).$VersionSuffix"
    $script:ReleaseNotes = [string] $Notes.Content

    # Establish assembly version number
    $script:AssemblyVersion = [version] "$($script:SemanticVersion.Major).0.0.0"
    $script:AssemblyFileVersion = [version] "$script:SemanticVersion.0"

    $script:NugetPackageVersion = New-NugetPackageVersion -Version $script:SemanticVersion -BranchName $BranchName -IsDefaultBranch $IsDefaultBranch
}

# Synopsis: Retrieve three part version information from .build\version.txt
# $script:AssemblyVersion = Major.Minor.Build.$VersionSuffix
# $script:AssemblyFileVersion = Major.Minor.Build.$VersionSuffix
# $script:ReleaseNotes = ''
# $script:NugetPackageVersion = $script:SemanticVersion or $script:SemanticVersion-branch
function GetVersionInformationFromVersionTxt([int] $VersionSuffix) {
    $script:AssemblyVersion = [System.Version] "$(Get-Content version.txt).$VersionSuffix"
    $script:AssemblyFileVersion = $script:AssemblyVersion
    $script:ReleaseNotes = ''

    $script:NugetPackageVersion = New-NugetPackageVersion -Version $script:AssemblyVersion -BranchName $BranchName -IsDefaultBranch $IsDefaultBranch
}

# Ensure the following are set
# $script:AssemblyVersion
# $script:AssemblyFileVersion
# $script:ReleaseNotes
# $script:NugetPackageVersion
task GenerateVersionInformation {
    "Retrieving version information"
    
    # For dev builds, version suffix is always 0
    $versionSuffix = 0
    if($env:BUILD_NUMBER) {
        $versionSuffix = $env:BUILD_NUMBER
    }
  
    throw 'TODO: Either rely on GetVersionInformationFromVersionTxt or GenerateSemVerInformationFromReleaseNotesMd - the latter is normal for libraries'
    # GetVersionInformationFromVersionTxt($versionSuffix)
    # GenerateSemVerInformationFromReleaseNotesMd($versionSuffix)
    
    TeamCity-SetBuildNumber $script:Version
    
    "AssemblyVersion = $script:AssemblyVersion"
    "AssemblyFileVersion = $script:AssemblyFileVersion"
    "NugetPackageVersion = $script:NugetPackageVersion"
    "ReleaseNotes = $script:ReleaseNotes"
}

# Synopsis: Restore the nuget packages of the Visual Studio solution
task RestoreNugetPackages {
    exec {
        & $NugetExe restore "$Solution" -Verbosity detailed
    }
}

# Synopsis: Update the nuget packages of the Visual Studio solution
task UpdateNugetPackages RestoreNugetPackages, {
    exec {
        & $NugetExe update "$Solution" -Verbosity detailed
    }
}

# Synopsis: Update the version info in all AssemblyInfo.cs
task UpdateVersionInfo GenerateVersionInformation, {
    "Updating assembly information"

    # Ignore anything under the Testing/ folder
    @(Get-ChildItem "$RootDir" AssemblyInfo.cs -Recurse) | where { $_.FullName -notlike "$RootDir\Testing\*" } | ForEach {
        Update-AssemblyVersion $_.FullName `
            -Version $script:AssemblyVersion `
            -FileVersion $script:AssemblyFileVersion `
            -InformationalVersion $script:NuGetPackageVersion
    }
}

# Synopsis: Update the nuspec dependencies versions based on the versions of the nuget packages that are being used
task UpdateNuspecVersionInfo {
    # Find all the packages.config
    $packageConfigs = Get-ChildItem "$RootDir" -Recurse -Filter "packages.config" `
                      | ?{ $_.fullname -notmatch "\\(.build)|(packages)\\" } `
                      | Resolve-Path

    # Update dependency verions in each of our .nuspec file based on what is in our packages.config
    Resolve-Path "$RootDir\Nuspec\*.nuspec" | Update-NuspecDependenciesVersions -PackagesConfigPaths $packageConfigs -verbose
}

# Synopsis: A task that makes sure our initialization tasks have been run before we can do anything useful
task Init CreateFolders, RestoreNugetPackages, GenerateVersionInformation

# Synopsis: Compile the Visual Studio solution
task Compile Init, UpdateVersionInfo, {
    try {
        exec {
            & "C:\Program Files (x86)\MSBuild\14.0\Bin\msbuild" `
                "$Solution" `
                /maxcpucount `
                /nodereuse:false `
                /target:Build `
                /p:Configuration=$Configuration `
                /flp1:verbosity=normal`;LogFile=$LogsDir\_msbuild.log.normal.txt `
                /flp2:WarningsOnly`;LogFile=$LogsDir\_msbuild.log.warnings.txt `
                /flp3:PerformanceSummary`;NoSummary`;verbosity=quiet`;LogFile=$LogsDir\_msbuild.log.performanceSummary.txt `
                /flp4:verbosity=detailed`;LogFile=$LogsDir\_msbuild.log.detailed.txt `
                /flp5:verbosity=diag`;LogFile=$LogsDir\_msbuild.log.diag.txt `
        }
    } finally {
        TeamCity-PublishArtifact "$LogsDir\_msbuild.log.* => logs/msbuild.$Configuration.logs.zip"
    }
}

# Synopsis: Run SmartAssembly on files that have saproj files for them
task SmartAssembly -If ($Configuration -eq 'Release') {
    throw 'TODO: use Invoke-SmartAssembly from the RedGate.Build module'
    # For example:
    # Get-Item "$RootDir\MSBuild\sa\*.saproj" | ForEach {
    #     $saInput = "$RootDir\Build\Release\$($_.BaseName)" | Resolve-Path
    #     $saOutput = "$RootDir\Build\Obfuscated\$($_.BaseName)"
    #     Invoke-SmartAssembly `
    #         -ProjectPath $_.FullName `
    #         -InputFilename $saInput `
    #         -OutputFilename $saOutput
    # }
}

# Synopsis: Sign all the RedGate assemblies (Release and Obfuscated)
task SignAssemblies -If ($Configuration -eq 'Release' -and $SigningServiceUrl -ne $null) {
    throw 'TODO: use Invoke-SigningService from the RedGate.Build module'
    # For example:
    # Get-Item -Path "$RootDir\Build\Release\*.*" `
    #     -Include 'Redgate*.dll', 'Redgate*.exe' `
    #     | Invoke-SigningService -SigningServiceUrl $SigningServiceUrl -Verbose
    #     
    # Get-Item -Path "$RootDir\Build\Obfuscated\*.*" `
    #     -Include 'Redgate*.dll', 'Redgate*.exe' `
    #     | Invoke-SigningService -SigningServiceUrl $SigningServiceUrl -Verbose        
}

# Synopsis: Execute our unit tests
task UnitTests {
    throw 'TODO: use Invoke-NUnitForAssembly and Merge-CoverageReports from the RedGate.Build module'
    # For example:
    # Invoke-NUnitForAssembly `
    #     -AssemblyPath "$RootDir\Build\Release\RedGate.Tests.dll" `
    #     -NUnitVersion "2.6.4" `
    #     -FrameworkVersion "net-4.0" `
    #     -EnableCodeCoverage $true `
    # 
    # Merge-CoverageReports `
    #     -SnapshotsDir "$RootDir\Build\Release"
}

# Synopsis: Build the nuget packages.
task BuildNugetPackages Init, UpdateNuspecVersionInfo, {
    New-Item $NugetPackageOutputDir -ItemType Directory -Force | Out-Null

    "$RootDir\Nuspec\*.nuspec" | Resolve-Path | ForEach {
        exec {
            & $NugetExe pack $_ `
                -version $NugetPackageVersion `
                -OutputDirectory $NugetPackageOutputDir `
                -BasePath $RootDir `
                -Properties "releaseNotes=$ReleaseNotes" `
                -NoPackageAnalysis
        }
    }
    TeamCity-PublishArtifact "$NugetPackageOutputDir\*.nupkg => NugetPackages"
}

# Synopsis: Publish the nuget packages (Teamcity only)
task PublishNugetPackages -If($PublishNugetPackages) {
  assert ($NugetFeedUrl -ne $null) '$NugetFeedUrl is missing. Cannot publish nuget packages'
  assert ($NugetFeedApiKey -ne $null) '$NugetFeedApiKey is missing. Cannot publish nuget packages'

  Get-ChildItem $NugetPackageOutputDir -Filter "*.nupkg" | ForEach {
    & $NugetExe push $_.FullName -Source $NugetFeedUrl -ApiKey $NugetFeedApiKey
  }
}

# Synopsis: Build the project.
task Build Init, Compile, SmartAssembly, SignAssemblies, BuildNugetPackages, UnitTests, PublishNugetPackages

# Synopsis: By default, Call the 'Build' task
task . Build
