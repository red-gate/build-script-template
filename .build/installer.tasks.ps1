# Contains tasks we use to build our installers

[CmdletBinding()]
param()

<#
.SYNOPSIS
Turn the mini installer .exe into a nuget package for consumption in the CFU bundles

.EXAMPLE
New-MiniInstallerPackage -BranchName foo -ProductName "SQL Compare" -Version 1.0.0.0 -IsDefaultBranch $false -PathToMiniInstaller "Build\MiniToolbelts"
#>
function New-MiniInstallerPackage {
param(
    [CmdletBinding()]
    [string] $BranchName,
    [string] $ProductName,
    [System.Version] $Version,
    [bool] $IsDefaultBranch = $false,
    [string] $PathToMiniInstallers = 'Build\MiniToolbelts'
)
    $PackageId = "$($productName)"
    
    $NuspecVersion = New-NugetPackageVersion -Version $Version -BranchName $BranchName -IsDefaultBranch $IsDefaultBranch
    New-InstallerNugetPackage -PackageId $PackageId -PathToMiniToolbeltDirectory $PathToMiniInstallers -Version $NuspecVersion
    $NugetPackageOutputDir = resolve-path "."
    TeamCity-PublishArtifact "$NugetPackageOutputDir\*.nupkg"
}

task Copy-InstallerFiles {
    New-Item "$RootDir\Build\Installers\Release\" -ItemType Directory -Force | Out-Null
    # Copy Release directory into a working directory for the installers
    Copy-Item "$RootDir\Build\Release\*" "$RootDir\Build\Installers\Release\" -Recurse -Force
    # Overwrite with any obfuscated files
    Copy-Item "$RootDir\Build\Obfuscated\*" "$RootDir\Build\Installers\Release\" -Recurse -Force
}

task Setup-InstallerPrerequisites {

    $BinDirectory = "$RootDir\Build\Installers"
    
    throw 'Ensure the WixVersion and copy locations are correct'
    
    Initialize-InstallerPrerequisites `
        -BuildDirectory $BinDirectory `
        -Branding 'SQL Toolbelt' `
        -WixVersion '2' `
        -NugetPackagesDirectory "$RootDir\packages"

    New-Item "$BinDirectory\Release\Wix2\" -ItemType Directory -Force | Out-Null
    Copy-Item "$RootDir\Install\Wix2\*" "$BinDirectory\Release\Wix2\" -Recurse -Force -Verbose
}

function New-Installer($ProductName) {

    $BinDirectory = "$RootDir\Build\Installers"

    $DumpFolder = Get-PathToDumpFolder `
        -ProductShortName $ProductName `
        -Version $Version `
        -BranchName $BranchName `
        -IsDefaultBranch $IsDefaultBranch
        
    Write-Host "Got dump folder at $DumpFolder"

    throw 'If you''re using wix 3 you may need the extra arguments -WixExtensions @("WixUtilExtension", "WixNetFxExtension")'
    
    New-Msi `
        -BuildDirectory $BinDirectory `
        -ProductShortName $ProductName `
        -Platform 'x86' `
        -Version $Version |
            Select -ExpandProperty MsiFilePath |
            Invoke-SigningService -SigningServiceUrl $SigningServiceUrl

    New-ToolbeltInstaller `
        -BuildDirectory $BinDirectory `
        -InstallerTitle $ProductName `
        -Platform 'x86' `
        -Version $Version `
        -InstallerType 'mini' `
        -PrerequisitesDirectoryPath "$RootDir\Install\Toolbelt\local" |
            Invoke-SigningService -SigningServiceUrl $SigningServiceUrl |
            Copy-FileToDumpFolder -DumpFolder $DumpFolder -verbose |
            TeamCity-PublishArtifact

    New-MiniInstallerPackage `
        -BranchName $BranchName `
        -ProductName $ProductName `
        -Version $Version `
        -IsDefaultBranch $IsDefaultBranch `
        -PathToMiniInstallers "$BinDirectory\Installer"
}

task Installer Copy-InstallerFiles, Init, Setup-InstallerPrerequisites, {
    assert ($SigningServiceUrl) '$SigningServiceUrl is missing. Cannot create installers'
  
    throw 'You probably want to ensure New-Installer is called here'
    # For example:
    # New-Installer -ProductName 'SQL Dependency Tracker'
}

