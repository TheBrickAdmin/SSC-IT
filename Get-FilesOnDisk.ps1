function Get-FilesOnDisk {
    <#
    .SYNOPSIS
        Searches for files on a disk based on specified filename(s) and path(s).

    .DESCRIPTION
        The Get-FilesOnDisk function searches for files on a disk using specified filenames and paths. 
        It leverages the Windows API for efficient file searching and supports concurrent runspaces 
        to optimize performance.

    .PARAMETER Filename
        A(n array of) string(s) to match files against.

    .PARAMETER Path
        A(n array of) path(s) to search within. Defaults to the root of the current location.

    .PARAMETER MaxRunSpaces
        The maximum number of concurrent runspaces. Defaults to half the number of logical processors.

    .EXAMPLE
        PS> Get-FilesOnDisk -Pattern "mylostfile.txt" -Path "C:\Users"
        C:\Users\The\File\Was\Found\Here\mylostfile.txt

    .EXAMPLE
        PS> Get-FilesOnDisk -Pattern @("mylostfile.txt", "myotherlostfile.txt") -Path "C:\Users"
        C:\Users\The\File\Was\Found\Here\mylostfile.txt
        C:\Users\The\File\Was\Found\On\Another\Location\myotherlostfile.txt

    .NOTES
        Author: Rein Leen
        Date:   13-09-2024
    #>

    param (
        [string[]]$Filename,
        [string[]]$Path = (Get-Location).Drive.Root, # Default to the root of the current drive
        [int]$MaxRunSpaces = (Get-CimInstance -ClassName Win32_Processor).NumberOfLogicalProcessors / 2 # Default to 50% of Logical Processors to prevent overloading the system
    )

    # Initialize Class required to leverage faster searches of files.
    Add-Type -Name "FileSearch" -Namespace "Win32" -MemberDefinition @"
        public struct WIN32_FIND_DATA {
            public uint dwFileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
            public uint nFileSizeHigh;
            public uint nFileSizeLow;
            public uint dwReserved0;
            public uint dwReserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string cFileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
            public string cAlternateFileName;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
        public static extern IntPtr FindFirstFile
            (string lpFileName, out WIN32_FIND_DATA lpFindFileData);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
        public static extern bool FindNextFile
            (IntPtr hFindFile, out WIN32_FIND_DATA lpFindFileData);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
        public static extern bool FindClose(IntPtr hFindFile);
"@
    
    # Create collection of directories to loop through
    # Use BlockingCollection instead of a standard array for threading resiliency
    $directoryList = [System.Collections.Concurrent.BlockingCollection[string]]::new()
    foreach ($filepath in $Path)
    {
        # Add filepath to directorylist and remove trailing backslash
        $directoryList.Add($filepath -replace "\\$")
    }

    # Initialize collection to contain found matches
    $fileList = [System.Collections.Concurrent.BlockingCollection[string]]::new()
    
    # Initialize runspaces
    $runSpaceList = [System.Collections.Generic.List[PSObject]]::new()
    $pool = [RunSpaceFactory]::CreateRunspacePool(1, $MaxRunSpaces)
    $pool.Open()
    
    # Get all files matching the search criteria
    foreach ($id in 1..$maxRunSpaces)
    {
        # Create and configure a new runspace
        $runSpace = [Powershell]::Create()
        $runSpace.RunspacePool = $pool
        [void]$runSpace.AddScript(
        {
            param
            (
                [string[]]$Filename,
                [System.Collections.Concurrent.BlockingCollection[string]]$directoryList,
                [System.Collections.Concurrent.BlockingCollection[string]]$fileList
            )
            $fileData = new-object Win32.FileSearch+WIN32_FIND_DATA
            $dir = $null
            if ($id -eq 1)
            {
                $delay = 0
            }
            else
            {
                $delay = 50
            }
            if ($directoryList.TryTake([ref]$dir, $delay))
            {
                do
                {
                    $handle = [Win32.FileSearch]::FindFirstFile("$dir\*", [ref]$fileData)
                    [void][Win32.FileSearch]::FindNextFile($handle, [ref]$fileData)
                    while ([Win32.FileSearch]::FindNextFile($handle, [ref]$fileData))
                    {
                        if (($fileData.dwFileAttributes -band 0x10))
                        {
                            $fullName = [string]::Join('\', $dir, $fileData.cFileName)
                            $directoryList.Add($fullName)
                        }
                        elseif ($fileData.cFileName -in $Filename)
                        {
                            $fullName = [string]::Join('\', $dir, $fileData.cFileName)
                            $fileList.Add($fullName)
                        }
                    }
                    [void][Win32.FileSearch]::FindClose($handle)
                }
                until (-not $directoryList.TryTake([ref]$dir))
            }
        })
        [void]$runSpace.addArgument($Filename)
        [void]$runSpace.addArgument($directoryList)
        [void]$runSpace.addArgument($fileList)
        $status = $runSpace.BeginInvoke()
        $runSpaceList.Add([PSCustomObject]@{Name = $id; RunSpace = $runSpace; Status = $status})
    }
    
    # Wait until all runspaces are done processing and dispose them afterwards.
    while ($runSpaceList | Where-Object { -not $_.Status.IsCompleted})
    {
        Start-Sleep -Milliseconds 100
    }
    $pool.Close() 
    $pool.Dispose()

    # Return the list of found files
    return $fileList
}