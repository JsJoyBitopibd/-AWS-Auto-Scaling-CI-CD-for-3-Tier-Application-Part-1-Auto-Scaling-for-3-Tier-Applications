# =====================================================================
#  Fix "UNPROTECTED PRIVATE KEY FILE" on Windows
# ---------------------------------------------------------------------
#  Windows OpenSSH refuses to use a .pem key if ANY group other than
#  your own user / Administrators / SYSTEM can read it.
#
#  Running only `icacls key.pem /grant:r "$env:USERNAME:(R)"` is NOT
#  enough: the inherited group entries (notably
#  "NT AUTHORITY\Authenticated Users") survive and SSH still refuses
#  with:  Permissions for 'key.pem' are too open.
#
#  The groups must be REMOVED explicitly. Run this from the folder
#  containing the key.
# =====================================================================

$Key = "bitopi-key.pem"

# 1) Stop inheriting permissions from the parent folder
icacls $Key /inheritance:r

# 2) Grant read access to the current user only
icacls $Key /grant:r "$($env:USERNAME):(R)"

# 3) Explicitly remove the groups OpenSSH objects to  <-- the vital step
icacls $Key /remove "NT AUTHORITY\Authenticated Users"
icacls $Key /remove "BUILTIN\Users"
icacls $Key /remove "Everyone"

# 4) Verify - should list ONLY your user, Administrators and SYSTEM
icacls $Key

# Expected output:
#   bitopi-key.pem  DOMAIN\your.user:(R)
#                   BUILTIN\Administrators:(F)
#                   NT AUTHORITY\SYSTEM:(F)
#
# Then connect:
#   ssh -i bitopi-key.pem ec2-user@<PUBLIC_IP>
