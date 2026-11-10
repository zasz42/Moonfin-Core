#!/usr/bin/env python3
"""
Merge banner_media_bar.dart conflict.
Beta.1 (HEAD) has: compact banner, tvOS pan gestures, trailer badges, upcoming rail
Main (origin/main) has: Focus wrapper, navigation dots, navigation arrows
"""

import re

with open('/home/plasma/projects/Moonfin-Core/lib/ui/widgets/mediabar/banner_media_bar.dart', 'r') as f:
    content = f.read()

# Find the conflict markers
start_marker = '<<<<<<< HEAD'
mid_marker = '======='
end_marker = '>>>>>>> origin/main'

start_idx = content.index(start_marker)
mid_idx = content.index(mid_marker)
end_idx = content.index(end_marker) + len(end_marker)

# The region from start_marker to end_marker (inclusive)
conflict_region = content[start_idx:end_idx]

print(f"Conflict region length: {len(conflict_region)} chars")
print(f"Start at: {start_idx}, Mid at: {mid_idx}, End at: {end_idx}")

# Split into ours and theirs
ours = content[start_idx + len(start_marker):mid_idx]
theirs = content[mid_idx + len(mid_marker):end_idx - len(end_marker)]

print(f"\n--- OURS (HEAD/beta.1) ---")
print(ours[:500])
print("...")
print(ours[-500:])

print(f"\n--- THEIRS (origin/main) ---")
print(theirs[:500])
print("...")
print(theirs[-500:])

# Now construct the merged version
# We need to replace from start_marker to the matching closing of the build method
# Let me find the end of the build method after the conflict

# The conflict region in the file spans from line 425 to line 541 (markers)
# After the conflict markers, the beta.1 version continues

# Let's find where the build method ends
build_method_start = content.rfind('  @override\n  Widget build(BuildContext context) {', 0, start_idx)
print(f"\nBuild method starts at: {build_method_start}")

# Find the end of the build method (matching brace)
brace_count = 0
in_method = False
method_end = -1
for i in range(build_method_start, len(content)):
    if content[i] == '{':
        brace_count += 1
        in_method = True
    elif content[i] == '}':
        brace_count -= 1
        if in_method and brace_count == 0:
            method_end = i
            break

print(f"Build method ends at: {method_end}")

# Let me check what's after the conflict markers
after_conflict = content[end_idx:method_end+1]
print(f"\n--- AFTER CONFLICT (first 2000 chars) ---")
print(after_conflict[:2000])