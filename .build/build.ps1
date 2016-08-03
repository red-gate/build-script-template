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

# Synopsis: Compute the value of the version info of SQL Source Control. (Save it in $script:Version for other tasks to use)
task GenerateVersionNumber {
  # For dev builds, version suffix is always 0
  $versionSuffix = 0
  if($env:BUILD_NUMBER) {
    $versionSuffix = $env:BUILD_NUMBER
  }

  $script:Version = [System.Version] "$(Get-Content version.txt).$versionSuffix"

  TeamCity-SetBuildNumber $script:Version

  $script:NugetPackageVersion = New-NugetPackageVersion -Version $script:Version -BranchName $BranchName -IsDefaultBranch $IsDefaultBranch

  "Version number is $script:Version"
  "Nuget packages Version number is $script:NugetPackageVersion"
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
task UpdateVersionInfo GenerateVersionNumber, {

    "Updating Version Info to $Version"

    # Ignore anything under the Testing/ folder
    @(Get-ChildItem "$RootDir" AssemblyInfo.cs -Recurse) | where { $_.FullName -notlike "$RootDir\Testing\*" } | ForEach {

        (Get-Content $_.FullName) `
            -replace 'AssemblyVersion\("\d+\.\d+\.\d+\.\d+"\)', "AssemblyVersion(""$Version"")" `
            -replace 'AssemblyFileVersion\("\d+\.\d+\.\d+\.\d+"\)', "AssemblyFileVersion(""$Version"")" `
            | Out-File $_.FullName -Encoding utf8
    }
}

# Synopsis: Update the nuspec dependencies versions based on the versions of the nuget packages that are being used
task UpdateNuspecVersionInfo {
    # Get the list of packages.config we use from packages\repository.config
    $packageConfigs = ([xml](Get-Content $RootDir\packages\repositories.config)).repositories.repository.path -replace '\.\.', "$RootDir"
    # Update dependency verions in each of our .nuspec file based on what is in our packages.config
    Resolve-Path "$RootDir\Nuspec\*.nuspec" | Update-NuspecDependenciesVersions -PackagesConfigPaths $packageConfigs -verbose
}

# Synopsis: A task that makes sure our initialization tasks have been run before we can do anything useful
task Init CreateFolders, RestoreNugetPackages, GenerateVersionNumber

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
    throw 'TODO: use Invoke-NUnitForAssembly from the RedGate.Build module'
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
