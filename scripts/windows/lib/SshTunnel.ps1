function Test-SafeSshUserName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$UserName
    )

    if ([string]::IsNullOrEmpty($UserName)) {
        return $false
    }

    # Reject shell metacharacters, quotes, whitespace, DEL, and control bytes
    # before applying the allow-list grammar below.
    if ($UserName -match '[\x00-\x20\x7F;&|''"`]') {
        return $false
    }

    $account = '[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?'
    $emailDomain = '[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?'
    return $UserName -match "^(?:${account}|${account}\\${account}|${account}@${emailDomain})$"
}
