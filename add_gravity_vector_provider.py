import sys

# The IDs we want to use (must be unique and 24 uppercase hex characters)
# We'll generate them randomly, but for simplicity we can use fixed ones that we hope are not used.
# Let's check the existing IDs in the backup file to avoid collisions.
# We'll read the backup file and collect all IDs that are 24 uppercase hex characters.
# Then we'll generate new ones that are not in that set.

import re
import random
import string

def generate_id(existing_ids):
    while True:
        new_id = ''.join(random.choices(string.ascii_uppercase + string.digits, k=24))
        if new_id not in existing_ids:
            return new_id

# Read the backup file
with open('NekozeFix.xcodeproj/project.pbxproj.backup', 'r') as f:
    content = f.read()

# Find all existing IDs that are 24 uppercase hex characters (as seen in the file)
# Pattern: [A-F0-9]{24}
existing_ids = set(re.findall(r'[A-F0-9]{24}', content))
print(f"Found {len(existing_ids)} existing IDs.")

# Generate new IDs for our file reference and build file
file_ref_id = generate_id(existing_ids)
build_file_id = generate_id(existing_ids - {file_ref_id})  # ensure they are different

print(f"Using file reference ID: {file_ref_id}")
print(f"Using build file ID: {build_file_id}")

# Now we'll process the file line by line and build the new content.
lines = content.splitlines(keepends=True)  # keep line endings
new_lines = []

# States
in_file_reference_section = False
in_build_file_section = False
in_services_group = False
in_services_children = False
in_sources_build_phase = False
in_sources_files = False

i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()

    # Detect section beginnings and endings
    if stripped == '/* Begin PBXFileReference section */':
        in_file_reference_section = True
        new_lines.append(line)
        i += 1
        continue
    if stripped == '/* End PBXFileReference section */':
        # We are at the end comment, insert our file reference before this line
        new_lines.append(f'{file_ref_id} /* GravityVectorProvider.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GravityVectorProvider.swift; sourceTree = "<group>";}};\n')
        in_file_reference_section = False
        new_lines.append(line)
        i += 1
        continue
    if stripped == '/* Begin PBXBuildFile section */':
        in_build_file_section = True
        new_lines.append(line)
        i += 1
        continue
    if stripped == '/* End PBXBuildFile section */':
        # We are at the end comment, insert our build file reference before this line
        new_lines.append(f'{build_file_id} /* GravityVectorProvider.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* GravityVectorProvider.swift */}};\n')
        in_build_file_section = False
        new_lines.append(line)
        i += 1
        continue

    # Detect Services group
    if '20DBBAF9304EEE2E00B43650 /* Services */' in line and '{' in line:
        in_services_group = True
        new_lines.append(line)
        i += 1
        continue
    if in_services_group and stripped.startswith('children = ('):
        in_services_children = True
        new_lines.append(line)
        i += 1
        continue
    if in_services_children:
        # We are in the children array, look for the closing parenthesis
        if ');' in line:
            # Insert our file reference before the closing parentius
            # Use the same indentation as the current line
            indent = line[:len(line) - len(line.lstrip())]
            new_lines.append(indent + f'                     {file_ref_id} /* GravityVectorProvider.swift */,\n')
            in_services_children = False
            in_services_group = False  # We are done with the Services group after this
            new_lines.append(line)
            i += 1
            continue
        else:
            new_lines.append(line)
            i += 1
            continue

    # Detect Sources build phase
    if 'A5000002 /* Sources */' in line and '{' in line:
        in_sources_build_phase = True
        new_lines.append(line)
        i += 1
        continue
    if in_sources_build_phase and stripped.startswith('files = ('):
        in_sources_files = True
        new_lines.append(line)
        i += 1
        continue
    if in_sources_files:
        # We are in the files array, look for the closing parenthesis
        if ');' in line:
            # Insert our build file reference before the closing parenthesis
            indent = line[:len(line) - len(line.lstrip())]
            new_lines.append(indent + f'                     {build_file_id} /* GravityVectorProvider.swift in Sources */,\n')
            in_sources_files = False
            in_sources_build_phase = False  # We are done with the Sources build phase after this
            new_lines.append(line)
            i += 1
            continue
        else:
            new_lines.append(line)
            i += 1
            continue

    # If we are in a section and haven't hit the end, just add the line
    if in_file_reference_section or in_build_file_section or in_services_group or in_services_children or in_sources_build_phase or in_sources_files:
        new_lines.append(line)
        i += 1
        continue

    # Default: just add the line
    new_lines.append(line)
    i += 1

# Write the new content to a temporary file and then replace the project.pbxproj
with open('NekozeFix.xcodeproj/project.pbxproj', 'w') as f:
    f.writelines(new_lines)

print('Project file updated with GravityVectorProvider.swift')
