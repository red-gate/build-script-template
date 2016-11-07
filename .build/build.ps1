[CmdletBinding()]
param(
    [string] $Configuration = 'Release',
    [string] $BranchName = 'dev',
    [bool] $IsDefaultBranch = $false,
    [string] $NugetFeedUrl,
    [string] $NugetFeedApiKey,
    [string] $SigningServiceUrl
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

# Installer building routines are stored in a separate file
# . $PSScriptRoot\installer.tasks.ps1

task CreateFolders {
    New-Item $OutputDir -ItemType Directory -Force | Out-Null
    New-Item $LogsDir -ItemType Directory -Force | Out-Null
    New-Item $NugetPackageOutputDir -ItemType Directory -Force | Out-Null
}

# Synopsis: Retrieve three part version information and release notes from $RootDir\RELEASENOTES.md
# $script:Version = Major.Minor.Build.$VersionSuffix (for installer.tasks)
# $script:AssemblyVersion = $script:Version
# $script:AssemblyFileVersion = $script:Version
# $script:ReleaseNotes = read from RELEASENOTES.md
function GenerateVersionInformationFromReleaseNotesMd([int] $VersionSuffix) {
    $ReleaseNotesPath = "$RootDir\RELEASENOTES.md" | Resolve-Path
    $Notes = Read-ReleaseNotes -ReleaseNotesPath $ReleaseNotesPath -ThreePartVersion
    $script:Version = [System.Version] "$($Notes.Version).$VersionSuffix"
    $script:ReleaseNotes = [string] $Notes.Content

    # Establish assembly version number
    $script:AssemblyVersion = $script:Version
    $script:AssemblyFileVersion = $script:Version
    
    TeamCity-PublishArtifact "$ReleaseNotesPath"
}

# Synopsis: Retrieve two part semantic version information and release notes from $RootDir\RELEASENOTES.md
# $script:Version = Major.Minor.$VersionSuffix
# $script:AssemblyVersion = Major.0.0.0
# $script:AssemblyFileVersion = Major.Minor.$VersionSuffix.0
# $script:ReleaseNotes = read from RELEASENOTES.md
function GenerateSemVerInformationFromReleaseNotesMd([int] $VersionSuffix) {
    $ReleaseNotesPath = "$RootDir\RELEASENOTES.md" | Resolve-Path
    $Notes = Read-ReleaseNotes -ReleaseNotesPath $ReleaseNotesPath
    $script:Version = [System.Version] "$($Notes.Version).$VersionSuffix"
    $script:ReleaseNotes = [string] $Notes.Content

    # Establish assembly version number
    $script:AssemblyVersion = [version] "$($script:Version.Major).0.0.0"
    $script:AssemblyFileVersion = [version] "$script:Version.0"
    
    TeamCity-PublishArtifact "$ReleaseNotesPath"
}

# Synopsis: Retrieve three part version information from .build\version.txt
# $script:Version = Major.Minor.Build.$VersionSuffix
# $script:AssemblyVersion = Major.Minor.Build.$VersionSuffix
# $script:AssemblyFileVersion = Major.Minor.Build.$VersionSuffix
# $script:ReleaseNotes = ''
function GetVersionInformationFromVersionTxt([int] $VersionSuffix) {
    $script:Version = [System.Version] "$(Get-Content version.txt).$VersionSuffix"
    $script:AssemblyVersion = $script:Version
    $script:AssemblyFileVersion = $script:Version
    $script:ReleaseNotes = ''
}

# Ensures the following are set
# $script:Version
# $script:AssemblyVersion
# $script:AssemblyFileVersion
# $script:ReleaseNotes
# $script:NugetPackageVersion = $script:Version or $script:Version-branch
task GenerateVersionInformation {
    "Retrieving version information"
    
    # For dev builds, version suffix is always 0
    $versionSuffix = 0
    if($env:BUILD_NUMBER) {
        $versionSuffix = $env:BUILD_NUMBER
    }
  
    throw 'TODO: Either rely on GetVersionInformationFromVersionTxt, GenerateVersionInformationFromReleaseNotesMd, or GenerateSemVerInformationFromReleaseNotesMd - the latter is normal for libraries'
    # GetVersionInformationFromVersionTxt($versionSuffix)
    # GenerateVersionInformationFromReleaseNotesMd($versionSuffix)
    # GenerateSemVerInformationFromReleaseNotesMd($versionSuffix)
    
    TeamCity-SetBuildNumber $script:Version
    
    $script:NugetPackageVersion = New-NugetPackageVersion -Version $script:Version -BranchName $BranchName -IsDefaultBranch $IsDefaultBranch
    
    "Version = $script:Version"
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
task SignAssemblies -If ($Configuration -eq 'Release' -and $SigningServiceUrl) {
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

    $escaped=$ReleaseNotes.Replace('"','\"')
    $properties = "releaseNotes=$escaped"
    
    "$RootDir\Nuspec\*.nuspec" | Resolve-Path | ForEach {
        exec {
            & $NugetExe pack $_ `
                -Version $NugetPackageVersion `
                -OutputDirectory $NugetPackageOutputDir `
                -BasePath $RootDir `
                -Properties $properties `
                -NoPackageAnalysis
        }
    }
    
    TeamCity-PublishArtifact "$NugetPackageOutputDir\*.nupkg => NugetPackages"
}

# Synopsis: Publish the nuget packages (Teamcity only)
task PublishNugetPackages -If($PublishNugetPackages) {
  assert ($NugetFeedUrl) '$NugetFeedUrl is missing. Cannot publish nuget packages'
  assert ($NugetFeedApiKey) '$NugetFeedApiKey is missing. Cannot publish nuget packages'

  Get-ChildItem $NugetPackageOutputDir -Filter "*.nupkg" | ForEach {
    & $NugetExe push $_.FullName -Source $NugetFeedUrl -ApiKey $NugetFeedApiKey
  }
}

task BuildArtifacts {
  TeamCity-PublishArtifact "$RootDir\Build\** => Build.zip"
}

# Synopsis: Build the project.
task Build Init, Compile, UnitTests, SmartAssembly, SignAssemblies, BuildArtifacts, BuildNugetPackages, PublishNugetPackages

# Synopsis: By default, Call the 'Build' task
task . Build
