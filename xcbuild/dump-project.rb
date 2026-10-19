# Dump an .xcodeproj (targets, files, phases, raw build settings) as JSON for xcbuild.py.
# usage: ruby dump-project.rb PROJECT.xcodeproj CONFIGURATION > out.json
require 'xcodeproj'
require 'json'

proj = Xcodeproj::Project.open(ARGV[0])
config = ARGV[1] || 'Release'
srcroot = File.dirname(File.expand_path(ARGV[0]))

def conf_dict(list, name, srcroot)
  c = list.build_configurations.find { |b| b.name == name }
  return { 'settings' => {}, 'xcconfig' => nil } unless c
  xc = c.base_configuration_reference && c.base_configuration_reference.real_path.to_s
  { 'settings' => c.build_settings, 'xcconfig' => xc }
end

def path_of(ref)
  ref && ref.respond_to?(:real_path) ? ref.real_path.to_s : nil
end

out = {
  'path' => File.expand_path(ARGV[0]),
  'srcroot' => srcroot,
  'name' => File.basename(ARGV[0], '.xcodeproj'),
  'project' => conf_dict(proj.build_configuration_list, config, srcroot),
  'targets' => []
}
# every header file reference in the project (Xcode's project-headers header map)
hext = %w[.h .hh .hpp .hxx .ipp .inl .tcc .def .pch]
out['header_refs'] = proj.files.map { |f| path_of(f) }.compact.select { |p| hext.include?(File.extname(p).downcase) }
proj.targets.each do |t|
  e = {
    'name' => t.name,
    'type' => t.respond_to?(:product_type) ? t.product_type.to_s : '',
    'product_name' => t.respond_to?(:product_name) ? t.product_name : t.name,
    'config' => conf_dict(t.build_configuration_list, config, srcroot),
    'deps' => t.dependencies.map { |d| d.target ? d.target.name : d.name }.compact,
    'phases' => []
  }
  t.build_phases.each do |ph|
    p = { 'isa' => ph.isa, 'name' => (ph.respond_to?(:name) ? ph.name : nil) }
    if ph.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
      p['script'] = ph.shell_script
      p['shell'] = ph.shell_path
      p['inputs'] = ph.input_paths || []
      p['outputs'] = ph.output_paths || []
      p['input_lists'] = ph.input_file_list_paths || []
      p['output_lists'] = ph.output_file_list_paths || []
      p['always'] = ph.respond_to?(:always_out_of_date) ? ph.always_out_of_date : nil
      p['dependency_file'] = ph.respond_to?(:dependency_file) ? ph.dependency_file : nil
    else
      p['files'] = ph.files.map do |bf|
        r = bf.file_ref
        f = { 'path' => path_of(r), 'settings' => bf.settings || {} }
        if r.is_a?(Xcodeproj::Project::Object::PBXReferenceProxy) || (r && r.respond_to?(:path) && r.source_tree == 'BUILT_PRODUCTS_DIR')
          f['built_product'] = r.path
        end
        if r.is_a?(Xcodeproj::Project::Object::PBXVariantGroup)
          f['variants'] = r.children.map { |c| path_of(c) }
        end
        f['name'] = r.respond_to?(:display_name) ? r.display_name : nil if r
        f['file_type'] = r.respond_to?(:last_known_file_type) ? (r.last_known_file_type || r.explicit_file_type) : nil if r
        f
      end
      if ph.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
        p['dst_subfolder'] = ph.dst_subfolder_spec
        p['dst_path'] = ph.dst_path
      end
    end
    e['phases'] << p
  end
  out['targets'] << e
end
puts JSON.pretty_generate(out)
