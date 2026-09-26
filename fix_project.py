import sys

# IDs for the new file reference and build file
file_ref_id = "F22BCD879D7957197724147A"
build_file_id = "D03EDF5EED1A3A308D1DCD1E"

# Read the backup file
with open('NekozeFix.xcodeproj/project.pbxproj.backup', 'r') as f:
    lines = f.readlines()

# We'll process the lines and build a new list
new_lines = []
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()

    # Check for the end of PBXFileReference section
    if stripped == '/* End PBXFileReference section */':
        # Insert the file reference before this line
        new_lines.append(f'{file_ref_id} /* GravityVectorProvider.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GravityVectorProvider.swift; sourceTree = "<group>";}};\n')
        new_lines.append(line)
        i += 1
        continue

    # Check for the end of PBXBuildFile section
    if stripped == '/* End PBXBuildFile section */':
        # Insert the build file reference before this line
        new_lines.append(f'{build_file_id} /* GravityVectorProvider.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* GravityVectorProvider.swift */}};\n')
        new_lines.append(line)
        i += 1
        continue

    # Check for the Services group children array
    # We look for the line that starts the Services group and then look for the children array
    if '20DBBAF9304EEE2E00B43650 /* Services */' in line and '{' in line:
        # We are in the Services group, now we look for the children array
        new_lines.append(line)
        i += 1
        # Now we look for the children array
        while i < len(lines) and not lines[i].strip().startswith('children = ('):
            new_lines.append(lines[i])
            i += 1
        if i < len(lines):
            # We found the children = ( line
            new_lines.append(lines[i])
            i += 1
        # Now we are in the children array, we add entries until we hit the closing parenthesis
        while i < len(lines) and not lines[i].strip().startswith(');'):
            new_lines.append(lines[i])
            i += 1
        if i < len(lines):
            # Before the closing parentius, insert our file reference
            indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
            new_lines.append(indent + f'                     {file_ref_id} /* GravityVectorProvider.swift */,\n')
            new_lines.append(lines[i])  # the ); line
            i += 1
        continue

    # Check for the Sources build phase files array
    if 'A5000002 /* Sources */' in line and '{' in line:
        new_lines.append(line)
        i += 1
        # Look for the files array
        while i < len(lines) and not lines[i].strip().startswith('files = ('):
            new_lines.append(lines[i])
            i += 1
        if i < len(lines):
            new_lines.append(lines[i])  # the files = ( line
            i += 1
        # Now we are in the files array
        while i < len(lines) and not lines[i].strip().startswith(');'):
            new_lines.append(lines[i])
            i += 1
        if i < len(lines):
            # Before the closing parentius, insert our build file reference
            indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
            new_lines.append(indent + f'                     {build_file_id} /* GravityVectorProvider.swift in Sources */,\n')
            new_lines.append(lines[i])  # the ); line
            i += 1
        continue

    # If none of the above, just add the line
    new_lines.append(line)
    i += 1

# Write the new content
with open('NekozeFix.xcodeproj/project.pbxproj', 'w') as f:
    f.writelines(new_lines)

print('Project file updated.')
