# All the tasks to manage building the Rubinius kernel--which is essentially
# the Ruby core library plus Rubinius-specific files. The kernel bootstraps
# a Ruby environment to the point that user code can be loaded and executed.
#
# The basic rule is that any generated file should be specified as a file
# task, not hidden inside some arbitrary task. Generated files are created by
# rule (e.g. the rule for compiling a .rb file into a .rbc file) or by a block
# attached to the file task for that particular file.
#
# The only tasks should be those names needed by the user to invoke specific
# parts of the build (including the top-level build task for generating the
# entire kernel).

require "rakelib/digest_files"

# drake does not allow invoke to be called inside tasks
def kernel_clean
  rm_rf Dir["**/*.rbc",
           "**/.*.rbc",
           "kernel/**/signature.rb",
           "runtime/kernel",
           "spec/capi/ext/*.{o,sig,#{$dlext}}",
          ],
    :verbose => $verbose
end

# TODO: Build this functionality into the compiler
class KernelCompiler
  def self.compile(file, output, line, transforms)
    compiler = Rubinius::ToolSets::Build::Compiler.new :file, :compiled_file

    parser = compiler.parser
    parser.root Rubinius::ToolSets::Build::AST::Script

    if transforms.kind_of? Array
      transforms.each { |t| parser.enable_category t }
    else
      parser.enable_category transforms
    end

    parser.input file, line

    generator = compiler.generator
    generator.processor Rubinius::ToolSets::Build::Generator

    writer = compiler.writer
    writer.name = output

    compiler.run
  end
end

# The rule for compiling all kernel Ruby files
rule ".rbc" do |t|
  source = t.prerequisites.first
  puts "RBC #{source}"
  KernelCompiler.compile source, t.name, 1, [:default, :kernel]
end

# Collection of all files in the kernel runtime. Modified by
# various tasks below.
runtime_files = FileList["runtime/platform.conf"]
code_db_files = FileList[
  "runtime/kernel/contents",
  "runtime/kernel/data",
  "runtime/kernel/index",
  "runtime/kernel/initialize",
  "runtime/kernel/signature"
]
code_db_scripts = []
code_db_code = []
code_db_data = []

# All the kernel files are listed in the `kernel_load_order`
kernel_load_order = "kernel/load_order.txt"
kernel_files = FileList[]

IO.foreach kernel_load_order do |name|
  kernel_files << "kernel/#{name.chomp}"
end

# Generate file tasks for all kernel and load_order files.
def file_task(re, runtime_files, signature, rb, rbc)
  rbc ||= ((rb.sub(re, "runtime") if re) || rb) + "c"

  file rbc => [rb, signature]
  runtime_files << rbc
end

def kernel_file_task(runtime_files, signature, rb, rbc=nil)
  file_task(/^kernel/, runtime_files, signature, rb, rbc)
end

# Generate a digest of the Rubinius runtime files
signature_file = "kernel/signature.rb"

bootstrap_files = FileList[
  "library/rbconfig.rb",
  "library/rubinius/build_config.rb",
]

runtime_gems_dir = BUILD_CONFIG[:runtime_gems_dir]
bootstrap_gems_dir = BUILD_CONFIG[:bootstrap_gems_dir]

if runtime_gems_dir and bootstrap_gems_dir
  ffi_files = FileList[
    "#{bootstrap_gems_dir}/**/*.ffi"
  ].each { |f| f.gsub!(/.ffi\z/, '') }

  runtime_gem_files = FileList[
    "#{runtime_gems_dir}/**/*.rb"
  ].exclude("#{runtime_gems_dir}/**/spec/**/*.rb",
            "#{runtime_gems_dir}/**/test/**/*.rb")

  bootstrap_gem_files = FileList[
    "#{bootstrap_gems_dir}/**/*.rb"
  ].exclude("#{bootstrap_gems_dir}/**/spec/**/*.rb",
            "#{bootstrap_gems_dir}/**/test/**/*.rb")

  ext_files = FileList[
    "#{bootstrap_gems_dir}/**/*.{c,h}pp",
    "#{bootstrap_gems_dir}/**/grammar.y",
    "#{bootstrap_gems_dir}/**/lex.c.*"
  ]
else
  ffi_files = runtime_gem_files = bootstrap_gem_files = ext_files = []
end

config_files = FileList[
  "Rakefile",
  "config.rb",
  "rakelib/*.rb",
  "rakelib/*.rake"
]

signature_files = kernel_files + config_files + runtime_gem_files + ext_files - ffi_files

file signature_file => signature_files do
  # Collapse the digest to a 64bit quantity
  hd = digest_files signature_files
  SIGNATURE_HASH = hd[0, 16].to_i(16) ^ hd[16,16].to_i(16) ^ hd[32,8].to_i(16)

  File.open signature_file, "wb" do |file|
    file.puts "# This file is generated by rakelib/kernel.rake. The signature"
    file.puts "# is used to ensure that the runtime files and VM are in sync."
    file.puts "#"
    file.puts "Rubinius::Signature = #{SIGNATURE_HASH}"
  end
end

signature_header = "vm/gen/signature.h"

file signature_header => signature_file do |t|
  File.open t.name, "wb" do |file|
    file.puts "#define RBX_SIGNATURE          #{SIGNATURE_HASH}ULL"
  end
end

# Index files for loading a particular version of the kernel.
directory(runtime_base_dir = "runtime")
runtime_files << runtime_base_dir

signature = "runtime/signature"
file signature => signature_file do |t|
  File.open t.name, "wb" do |file|
    puts "GEN #{t.name}"
    file.puts Rubinius::Signature
  end
end
runtime_files << signature

# Build the bootstrap files
bootstrap_files.each do |name|
  file_task nil, runtime_files, signature_file, name, nil
end

# Build the gem files
runtime_gem_files.each do |name|
  file_task nil, runtime_files, signature_file, name, nil
end

# Build the bootstrap gem files
bootstrap_gem_files.each do |name|
  file_task nil, runtime_files, signature_file, name, nil
end

namespace :compiler do
  task :load => ['compiler:generate'] do
    require "rubinius/bridge"
    require "rubinius/code/toolset"

    Rubinius::ToolSets.create :build do
      require "rubinius/code/melbourne"
      require "rubinius/code/processor"
      require "rubinius/code/compiler"
      require "rubinius/code/ast"
    end

    require File.expand_path("../../kernel/signature", __FILE__)
  end

  task :generate => [signature_file]
end

directory "runtime/kernel"

class CodeDBCompiler
  def self.m_id
    @m_id ||= 0
    (@m_id += 1).to_s
  end

  def self.compile(file, line, transforms)
    compiler = Rubinius::ToolSets::Build::Compiler.new :file, :compiled_code

    parser = compiler.parser
    parser.root Rubinius::ToolSets::Build::AST::Script

    if transforms.kind_of? Array
      transforms.each { |t| parser.enable_category t }
    else
      parser.enable_category transforms
    end

    parser.input file, line

    generator = compiler.generator
    generator.processor Rubinius::ToolSets::Build::Generator

    compiler.run
  end

  def self.marshal(code)
    marshaler = Rubinius::ToolSets::Build::CompiledFile::Marshal.new
    marshaler.marshal code
  end
end

file "runtime/kernel/data" => ["runtime/kernel"] + runtime_files do |t|
  puts "CodeDB: writing data..."

  kernel_files.each do |file|
    id = CodeDBCompiler.m_id

    code_db_code << [id, CodeDBCompiler.compile(file, 1, [:default, :kernel])]

    code_db_scripts << [file, id]
  end

  while x = code_db_code.shift
    id, cc = x

    cc.literals.each_with_index do |x, index|
      if x.kind_of? Rubinius::CompiledCode
        cc.literals[index] = i = CodeDBCompiler.m_id
        code_db_code.unshift [i, x]
      end
    end

    marshaled = CodeDBCompiler.marshal cc

    code_db_data << [id, marshaled]
  end

  File.open t.name, "wb" do |f|
    code_db_data.map! do |id, marshaled|
      offset = f.pos
      f.write marshaled

      [id, offset, f.pos - offset]
    end
  end
end

file "runtime/kernel/index" => "runtime/kernel/data" do |t|
  puts "CodeDB: writing index..."

  File.open t.name, "wb" do |f|
    code_db_data.each { |id, offset, length| f.puts "#{id} #{offset} #{length}" }
  end
end

file "runtime/kernel/contents" => "runtime/kernel/data" do |t|
  puts "CodeDB: writing contents..."

  File.open t.name, "wb" do |f|
    code_db_scripts.each { |file, id| f.puts "#{file} #{id}" }
  end
end

file "runtime/kernel/initialize" => "runtime/kernel/data" do |t|
  puts "CodeDB: writing initialize..."

  File.open t.name, "wb" do |f|
    code_db_scripts.each { |_, id| f.puts id }
  end
end

file "runtime/kernel/signature" => signature_file do |t|
  puts "CodeDB: writing signature..."

  File.open t.name, "wb" do |f|
    f.puts Rubinius::Signature
  end
end

desc "Build all kernel files (alias for kernel:build)"
task :kernel => 'kernel:build'

namespace :kernel do
  desc "Build all kernel files"
  task :build => ['compiler:load'] + runtime_files + code_db_files

  desc "Delete all .rbc files"
  task :clean do
    kernel_clean
  end
end
