require 'sketchup'
require 'extensions'
require 'json'

module SU_MCP
  unless file_loaded?(__FILE__)
    # Single-source the version from extension.json so this file can't drift.
    # Release builds stamp extension.json from the git tag; local builds ship as "local".
    manifest = JSON.parse(File.read(File.join(__dir__, 'extension.json')))

    ext = SketchupExtension.new('Sketchup MCP Server', 'su_mcp/main')
    ext.description = 'Model Context Protocol server for Sketchup'
    ext.version     = manifest['version']
    ext.copyright   = '2024'
    ext.creator     = 'MCP Team'
    
    Sketchup.register_extension(ext, true)
    
    file_loaded(__FILE__)
  end
end 