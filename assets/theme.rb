require "yaml"
require "json"

File.write("#{__dir__}/theme.json", YAML.load_file("#{__dir__}/theme.yml").to_json)
