#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds a standalone development ScreenQBroadcastExtension target to the Screen Q
# Xcode project. Public app builds must not depend on or embed this target until
# the ReplayKit upload transport is implemented and reviewed.
#
# Run from the project root:
#
#   ruby Scripts/add_broadcast_extension.rb
#
# The script is idempotent: if the target already exists it bails out.
# A backup of project.pbxproj is created next to the file before writing.

require "xcodeproj"
require "fileutils"

PROJECT_PATH      = "Screen Q.xcodeproj"
HOST_TARGET_NAME  = "Screen Q"
EXT_TARGET_NAME   = "ScreenQBroadcastExtension"
DEFAULT_APP_BUNDLE_ID = ENV.fetch("SCREENQ_BUNDLE_ID", "com.example.Screen-Q")
EXT_BUNDLE_ID     = ENV.fetch("SCREENQ_BROADCAST_EXTENSION_BUNDLE_ID", "#{DEFAULT_APP_BUNDLE_ID}.ScreenQBroadcastExtension")
DEV_TEAM          = ENV["DEVELOPMENT_TEAM"]
EXT_FOLDER        = "ScreenQBroadcastExtension"
IOS_DEPLOY_TARGET = ENV.fetch("IOS_DEPLOYMENT_TARGET", "17.0")
SWIFT_VERSION     = "5.0"

abort "❌ #{PROJECT_PATH} not found" unless File.directory?(PROJECT_PATH)
abort "❌ #{EXT_FOLDER}/ not found"  unless File.directory?(EXT_FOLDER)

backup = "#{PROJECT_PATH}/project.pbxproj.bak.#{Time.now.strftime("%Y%m%d-%H%M%S")}"
FileUtils.cp("#{PROJECT_PATH}/project.pbxproj", backup)
puts "🗄  Backed up pbxproj to #{backup}"

project = Xcodeproj::Project.open(PROJECT_PATH)

if project.targets.any? { |t| t.name == EXT_TARGET_NAME }
  puts "✅ #{EXT_TARGET_NAME} target already exists — nothing to do"
  exit 0
end

# ----------------------------------------------------------------------------
# 1. Create the extension target
# ----------------------------------------------------------------------------

ext_target = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
ext_target.name = EXT_TARGET_NAME
ext_target.product_name = EXT_TARGET_NAME
ext_target.product_type = "com.apple.product-type.app-extension"
ext_target.build_configuration_list =
  Xcodeproj::Project::ProjectHelper.configuration_list(
    project, :ios, IOS_DEPLOY_TARGET, ext_target, :swift
  )

# Ensure both Debug + Release have the bundle id, codesign, etc.
ext_target.build_configurations.each do |config|
  bs = config.build_settings
  bs["PRODUCT_BUNDLE_IDENTIFIER"]            = EXT_BUNDLE_ID
  bs["PRODUCT_NAME"]                         = "$(TARGET_NAME)"
  bs["SCREENQ_BUNDLE_ID"]                    = DEFAULT_APP_BUNDLE_ID
  bs["DEVELOPMENT_TEAM"]                     = DEV_TEAM if DEV_TEAM
  bs["CODE_SIGN_STYLE"]                      = "Automatic"
  bs["INFOPLIST_FILE"]                       = "#{EXT_FOLDER}/Info.plist"
  bs["GENERATE_INFOPLIST_FILE"]              = "NO"
  bs["IPHONEOS_DEPLOYMENT_TARGET"]           = IOS_DEPLOY_TARGET
  bs["SUPPORTED_PLATFORMS"]                  = "iphoneos iphonesimulator"
  bs["TARGETED_DEVICE_FAMILY"]               = "1,2"
  bs["SWIFT_VERSION"]                        = SWIFT_VERSION
  bs["SWIFT_DEFAULT_ACTOR_ISOLATION"]        = "MainActor"
  bs["SWIFT_APPROACHABLE_CONCURRENCY"]       = "YES"
  bs["SWIFT_EMIT_LOC_STRINGS"]               = "YES"
  bs["SDKROOT"]                              = "iphoneos"
  bs["SKIP_INSTALL"]                         = "YES"
  bs["LD_RUNPATH_SEARCH_PATHS"]              = "@executable_path/Frameworks @executable_path/../../Frameworks"
  bs["MARKETING_VERSION"]                    = "1.0"
  bs["CURRENT_PROJECT_VERSION"]              = "1"
  bs["MTL_ENABLE_DEBUG_INFO"]                = "INCLUDE_SOURCE"  if config.name == "Debug"
  bs["MTL_FAST_MATH"]                        = "YES"
  bs["ENABLE_USER_SCRIPT_SANDBOXING"]        = "YES"
  bs["CLANG_ENABLE_MODULES"]                 = "YES"
  bs["DEBUG_INFORMATION_FORMAT"]             = (config.name == "Debug" ? "dwarf" : "dwarf-with-dsym")
end

project.targets << ext_target

# ----------------------------------------------------------------------------
# 2. Add file references and the source build phase
# ----------------------------------------------------------------------------

main_group = project.main_group
ext_group  = main_group.find_subpath(EXT_FOLDER, true)
ext_group.set_source_tree("SOURCE_ROOT")
ext_group.path = EXT_FOLDER

def file_ref_for(group, path, last_known_file_type = nil)
  existing = group.files.find { |f| f.path == File.basename(path) }
  return existing if existing

  ref = group.new_file(File.basename(path))
  ref.last_known_file_type = last_known_file_type if last_known_file_type
  ref
end

sample_ref = file_ref_for(ext_group, "SampleHandler.swift", "sourcecode.swift")
setup_ref  = file_ref_for(ext_group, "BroadcastSetupViewController.swift", "sourcecode.swift")
info_ref   = file_ref_for(ext_group, "Info.plist", "text.plist.xml")

# Sources build phase
sources_phase = ext_target.new_shell_script_build_phase("Sources placeholder").tap(&:remove_from_project) # noop placeholder, replaced below
sources_phase = ext_target.source_build_phase
sources_phase.add_file_reference(sample_ref)
sources_phase.add_file_reference(setup_ref)

# Frameworks build phase: link ReplayKit + UIKit
frameworks_phase = ext_target.frameworks_build_phase

%w[ReplayKit UIKit Foundation].each do |fw|
  next if frameworks_phase.files.any? { |f| f.file_ref&.path == "System/Library/Frameworks/#{fw}.framework" }

  frameworks_group = project.frameworks_group
  fw_ref = frameworks_group.files.find { |f| f.name == "#{fw}.framework" || f.path == "System/Library/Frameworks/#{fw}.framework" }
  unless fw_ref
    fw_ref = frameworks_group.new_file("System/Library/Frameworks/#{fw}.framework", :sdk_root)
    fw_ref.last_known_file_type = "wrapper.framework"
  end
  frameworks_phase.add_file_reference(fw_ref)
end

# Resources build phase (empty for the extension)
ext_target.resources_build_phase

project.save
puts "✅ Added target '#{EXT_TARGET_NAME}' to #{PROJECT_PATH}"
puts "   - Bundle id: #{EXT_BUNDLE_ID}"
puts "   - Sources:   #{EXT_FOLDER}/SampleHandler.swift, #{EXT_FOLDER}/BroadcastSetupViewController.swift"
puts "   - Info.plist: #{EXT_FOLDER}/Info.plist"
puts "   - Standalone development target only; not embedded into '#{HOST_TARGET_NAME}'"
