# SPDX-License-Identifier: MPL-2.0
# register.ncl - MIME Registration Logic for .k9 SVC
#
# Generates OS-specific MIME type registration based on target environment.
# Used by: just register
let OS = [| 'Linux, 'Minix, 'MacOS |] in

{
  # Freedesktop MIME XML for Linux/Minix
  mime_xml = m%"
<?xml version="1.0" encoding="UTF-8"?>
<!-- SPDX-License-Identifier: MPL-2.0 -->
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/vnd.metadatastician.k9">
    <comment>K9 Self-Validating Component</comment>
    <comment xml:lang="en">K9 Self-Validating Component (Alpha Breed)</comment>
    <magic priority="50">
      <match value="K9!" type="string" offset="0"/>
    </magic>
    <glob pattern="*.k9"/>
    <glob pattern="*.k9.ncl"/>
    <sub-class-of type="application/x-nickel"/>
  </mime-type>
</mime-info>
"%,

  # macOS UTI plist fragment
  macos_uti = m%"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>org.k9-svc.component</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
        <string>public.text</string>
      </array>
      <key>UTTypeDescription</key>
      <string>K9 Self-Validating Component</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>k9</string>
          <string>k9.ncl</string>
        </array>
        <key>public.mime-type</key>
        <string>application/vnd.metadatastician.k9</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
"%,

  # Path resolution based on OS
  Config = fun os =>
    let paths = {
      Linux = {
        dest = "/usr/share/mime/packages/k9.xml",
        update_cmd = "update-mime-database /usr/share/mime",
        user_dest = "~/.local/share/mime/packages/k9.xml",
        user_update = "update-mime-database ~/.local/share/mime",
      },
      Minix = {
        dest = "/etc/mime.types.d/k9.xml",
        update_cmd = "true", # Minix uses static mapping
        user_dest = "~/.mime/k9.xml",
        user_update = "true",
      },
      MacOS = {
        dest = "/Library/Application Support/K9/k9.uti.plist",
        update_cmd = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Library/Application\\ Support/K9/k9.uti.plist",
        user_dest = "~/Library/Application Support/K9/k9.uti.plist",
        user_update = "true",
      },
    }
    in
    paths."%{std.string.from_enum os}",

  # Registration instructions
  registration_notes = m%"
K9 MIME Registration
====================

System-wide (requires root/admin):
  ./must run register-system

User-only:
  ./must run register-user

Verification:
  file --mime-type example.k9
  # Should output: application/vnd.metadatastician.k9

Manual registration:
  Linux: Copy k9.xml to /usr/share/mime/packages/ then run update-mime-database
  macOS: Copy k9.uti.plist to ~/Library/Application Support/K9/
  Minix: Add to /etc/mime.types
"%,
}
