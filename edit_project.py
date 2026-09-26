import plistlib
import sys

# Load the project file as a plist (it's actually a plist despite the extension)
with open('NekozeFix.xcodeproj/project.pbxproj', 'rb') as f:
    data = plistlib.load(f)

# Generate new IDs
import os
import hashlib
def new_id():
    # Generate a 24-character uppercase hex string
    return hashlib.md5(os.urandom(16)).hexdigest().upper()[:24]

file_ref_id = new_id()
build_file_id = new_id()

# Add file reference
file_ref = {
    'ISA': 'PBXFileReference',
    'lastKnownFileType': 'sourcecode.swift',
    'path': 'GravityVectorProvider.swift',
    'sourceTree': '<group>'
}
data['objects'][file_ref_id] = file_ref

# Add to Services group children
services_group_id = '20DBBAF9304EEE2E00B43650'
services_group = data['objects'][services_group_id]
children = services_group['children']
children.append(file_ref_id + ' /* GravityVectorProvider.swift */')
services_group['children'] = children

# Add to Sources build phase
sources_id = 'A5000002'
sources = data['objects'][sources_id]
files = sources['files']
files.append(build_file_id + ' /* GravityVectorProvider.swift in Sources */')
sources['files'] = files

# Add build file reference
build_file = {
    'ISA': 'PBXBuildFile',
    'fileRef': file_ref_id + ' /* GravityVectorProvider.swift */'
}
data['objects'][build_file_id] = build_file

# Write back
with open('NekozeFix.xcodeproj/project.pbxproj', 'wb') as f:
    plistlib.dump(data, f)

print(f'Added GravityVectorProvider.swift with fileRef {file_ref_id} and buildFile {build_file_id}')
