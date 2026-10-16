@{
    Name        = 'Huntress'
    Version     = '2'
    Description = 'Deploys the Huntress agent to every computer: the installer script (NSP.ClientScripts HuntressInstaller) on a file share, and a GPO that copies it to C:\ProgramData\NSP\Huntress (locked to SYSTEM and Administrators by the script) and runs that copy as SYSTEM - at registration, every unlock, startup and daily; it exits at once when the agent is installed and healthy. Each run reports back to Status\ and Transcripts\ next to the script.'

    # The GPO this recipe creates (or updates in place on a re-run).
    GpoName     = 'NSP - Deploy Huntress'
    # Folder (next to this file) holding the portable GPO backup: manifest.xml + {GUID}\.
    Backup      = 'Backup'

    # Asked for when not passed in -Values. Pattern is checked on every answer; Secret reads masked.
    Prompts     = @(
        @{ Name = 'OrganizationKey'; Prompt = 'Huntress organization key (usually the client short name)'; Pattern = '^[^\r\n''"]{1,100}$' }
        @{ Name = 'AccountKey';      Prompt = 'Huntress account key (32 hex characters)';                   Pattern = '^[A-Fa-f0-9]{32}$'; Secret = $true }
    )

    # The share folder's default name, shown when asking for it: \\server\share\<ShareFolder>.
    ShareFolder = 'Huntress'
    # Subfolders the computers may create and write files in (Authenticated Users, on top of read).
    ReportFolders = @('Status', 'Transcripts')

    # The script served from the share root. Only SYSTEM, administrators, domain computers and
    # domain controllers may read it - it carries the account key.
    Payload     = @{
        ClientScriptRecipe = 'HuntressInstaller'
        FileName           = 'HuntressInstall.ps1'
        # {Name} is a prompt answer or a built-in: {ShareRoot}, {PayloadPath}, {GpoName}.
        Parameters         = @{
            AccountKey      = '{AccountKey}'
            OrganizationKey = '{OrganizationKey}'
            ReportDirectory = '{ShareRoot}'
            # Where the GPO's Files preference copies the script (Backup\...\Files.xml targetPath).
            LocalDirectory  = 'C:\ProgramData\NSP\Huntress'
            Company         = '{OrganizationKey}'
        }
    }

    # Tokens in the GPO backup's XML and what replaces them (XML-escaped on the way in): the Files
    # preference copies from {PayloadPath} on the share; the task runs the local copy.
    GpoTokens   = @{
        '__NSP_HUNTRESS_SCRIPT__' = '{PayloadPath}'
    }
}
