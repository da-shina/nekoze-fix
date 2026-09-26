import sys

# The IDs we want to use (must be unique and 24 uppercase hex characters)
# We'll use the ones we have been using, but let's check if they are already in the backup file.
# If they are, we'll generate new ones.

import re

def get_existing_ids(content):
    # Find all 24-char uppercase hex strings
    return set(re.findall(r'[A-F0-9]{24}', content))

# Read the backup file
with open('NekozeFix.xcodeproj/project.pbxproj.backup', 'r') as f:
    backup_content = f.read()

existing_ids = get_existing_ids(backup_content)
print(f"Existing IDs count: {len(existing_ids)}")

# We want to use these IDs, but if they exist, we'll generate new ones.
desired_file_ref_id = "F22BCD879D7957197724147A"
desired_build_file_id = "D03EDF5EED1A3A308D1DCD1E"

if desired_file_ref_id in existing_ids or desired_build_file_id in existing_ids:
    # Generate new IDs that are not in existing_ids
    import random
    import string
    def generate_id():
        while True:
            new_id = ''.join(random.choices(string.ascii_uppercase + string.digits, k=24))
            if new_id not in existing_ids:
                return new_id
    file_ref_id = generate_id()
    build_file_id = generate_id()
    print(f"Generated new IDs: file_ref={file_ref_id}, build_file={build_file_id}")
else:
    file_ref_id = desired_file_ref_id
    build_file_id = desired_build_file_id
    print(f"Using desired IDs: file_ref={file_ref_id}, build_file={build_file_id}")

# Now we'll process the backup file line by line and build the new content.
lines = backup_content.splitlines(keepends=True)  # keep line endings
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
            # Insert our file reference before the closing parenthesis
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

# Write the new content to the project.pbxproj
with open('NekozeFix.xcodeproj/project.pbxproj', 'w') as f:
    f.writelines(new_lines)

print('Project file updated with GravityVectorProvider.swift')
