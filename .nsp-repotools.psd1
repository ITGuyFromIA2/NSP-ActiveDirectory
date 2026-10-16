@{
    # Settings for Find-NSPClientReference (NSP.RepoTools). Tracked: name what is accepted, never a client.
    ClientSweep = @{
        ExcludePath = @()
        Allow = @(
            # The placeholder DC in portable GPO backups (GpoBackupHelpers: DC.contoso.com -> this PDC).
            '\\DC.contoso.com\sysvol'
        )
        AllowPattern = @()
    }
}