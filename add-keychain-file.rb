#!/usr/bin/env ruby
# Add KeychainStore.swift to the SpeechCraft Xcode project.
# Run once after creating the file. Idempotent — safe to re-run.

require 'xcodeproj'

project_path = File.expand_path('speechcraft/speechcraft/SpeechCraft.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

# Find the main app target
target = project.targets.find { |t| t.name == 'SpeechCraft' }
abort('SpeechCraft target not found') unless target

# Find the Source group where the other Swift files live
source_group = project.main_group.find_subpath('Source', false)
abort('Source group not found') unless source_group

# Path to the file we want to add (relative to the group)
file_name = 'KeychainStore.swift'
file_path = File.join(File.dirname(project_path), 'Source', file_name)
abort("File not found: #{file_path}") unless File.exist?(file_path)

# Skip if already in the project
existing = source_group.files.find { |f| f.path == file_name }
if existing
  puts "Already in project: #{file_name}"
  exit 0
end

# Add file reference to the group and link to the target
file_ref = source_group.new_reference(file_name)
target.add_file_references([file_ref])

project.save
puts "Added #{file_name} to SpeechCraft target."
