#!/usr/bin/env ruby
require "xcodeproj"

proj_path = "PastScreen-CN.xcodeproj"
proj = Xcodeproj::Project.open(proj_path)

target = proj.targets.find { |t| t.name == "PastScreen-CN" }
sources_phase = target.source_build_phase

# Files that actually exist on disk
existing_files = Dir.glob("PastScreen/**/*.swift").map { |p| File.basename(p) }

# Files currently in sources build phase
build_phase_files = sources_phase.files.map { |f| f.file_ref.display_name }

puts "Existing on disk: #{existing_files.count}"
puts "In build phase: #{build_phase_files.count}"

# Remove from build phase any file not on disk
build_phase_files.each do |name|
  next if existing_files.include?(name)
  puts "Removing from build phase: #{name}"
  file_ref = sources_phase.files.find { |f| f.file_ref.display_name == name }
  sources_phase.remove_build_file(file_ref) if file_ref
end

# Add to build phase any existing file not already there
existing_files.each do |name|
  next if build_phase_files.include?(name)
  puts "Adding to build phase: #{name}"
  # Find or create file reference
  file_ref = proj.files.find { |f| f.display_name == name }
  unless file_ref
    # Need to find the actual path
    path = Dir.glob("PastScreen/**/#{name}").first
    raise "Cannot find path for #{name}" unless path
    # Create file ref under correct group later
    puts "  (will create ref for #{path})"
  end
end

# Build group structure
main = proj.main_group

# Remove all existing groups except Recovered References and tests
# Actually, let's just find or create a "PastScreen" group
pastscreen_group = main.groups.find { |g| (g.path || g.display_name) == "PastScreen" }
if pastscreen_group.nil?
  pastscreen_group = main.new_group("PastScreen", "PastScreen")
end

# Create subgroups
subgroups = {
  "Application" => "Application",
  "Components" => "Components",
  "Domain" => "Domain",
  "Infrastructure" => "Infrastructure",
  "Models" => "Models",
  "Services" => "Services",
  "Utils" => "Utils",
  "Views" => "Views"
}

group_map = {}
subgroups.each do |name, path|
  g = pastscreen_group.groups.find { |cg| (cg.path || cg.display_name) == name }
  if g.nil?
    g = pastscreen_group.new_group(name, path)
  else
    g.path = path
  end
  group_map[name] = g
end

# Special case: PastScreenApp.swift goes in PastScreen root
# Also handle tests
tests_group = main.groups.find { |g| (g.path || g.display_name) == "PastScreen-CNTests" }

# Move all file references into correct groups
proj.files.each do |file_ref|
  next unless file_ref.display_name.end_with?(".swift")
  name = file_ref.display_name

  # Find actual path on disk
  actual_path = Dir.glob("PastScreen/**/#{name}").first || Dir.glob("PastScreen-CNTests/**/#{name}").first
  next unless actual_path

  # Determine target group
  if actual_path.start_with?("PastScreen-CNTests/")
    target_group = tests_group
  elsif name == "PastScreenApp.swift"
    target_group = pastscreen_group
  elsif actual_path.include?("/Application/")
    target_group = group_map["Application"]
  elsif actual_path.include?("/Components/")
    target_group = group_map["Components"]
  elsif actual_path.include?("/Domain/")
    target_group = group_map["Domain"]
  elsif actual_path.include?("/Infrastructure/")
    target_group = group_map["Infrastructure"]
  elsif actual_path.include?("/Models/")
    target_group = group_map["Models"]
  elsif actual_path.include?("/Services/")
    target_group = group_map["Services"]
  elsif actual_path.include?("/Utils/")
    target_group = group_map["Utils"]
  elsif actual_path.include?("/Views/")
    target_group = group_map["Views"]
  else
    target_group = pastscreen_group
  end

  next if target_group.nil?

  # Move file ref to target group if not already there
  if file_ref.parent != target_group
    puts "Moving #{name} to #{target_group.display_name}"
    file_ref.remove_from_project
    new_ref = target_group.new_file(actual_path)
    new_ref.last_known_file_type = "sourcecode.swift"
    new_ref.source_tree = "<group>"

    # Update build phase to point to new ref
    bf = sources_phase.files.find { |f| f.file_ref.display_name == name }
    if bf
      bf.file_ref = new_ref
    else
      sources_phase.add_file_reference(new_ref)
    end
  end
end

# Also ensure all existing files on disk that don't have refs yet are added
existing_files.each do |name|
  file_ref = proj.files.find { |f| f.display_name == name }
  next if file_ref

  actual_path = Dir.glob("PastScreen/**/#{name}").first
  next unless actual_path

  target_group = if actual_path.include?("/Application/")
                   group_map["Application"]
                 elsif actual_path.include?("/Components/")
                   group_map["Components"]
                 elsif actual_path.include?("/Domain/")
                   group_map["Domain"]
                 elsif actual_path.include?("/Infrastructure/")
                   group_map["Infrastructure"]
                 elsif actual_path.include?("/Models/")
                   group_map["Models"]
                 elsif actual_path.include?("/Services/")
                   group_map["Services"]
                 elsif actual_path.include?("/Utils/")
                   group_map["Utils"]
                 elsif actual_path.include?("/Views/")
                   group_map["Views"]
                 elsif name == "PastScreenApp.swift"
                   pastscreen_group
                 else
                   pastscreen_group
                 end

  next if target_group.nil?

  puts "Creating ref + build phase for #{name}"
  new_ref = target_group.new_file(actual_path)
  new_ref.last_known_file_type = "sourcecode.swift"
  new_ref.source_tree = "<group>"
  sources_phase.add_file_reference(new_ref)
end

# Clean up empty Recovered References group
recovered = main.groups.find { |g| (g.path || g.display_name) == "Recovered References" }
if recovered && recovered.children.empty?
  recovered.remove_from_project
end

proj.save
puts "Project saved."
