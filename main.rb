require 'utils'
require 'uri'

class Cmds
  def cmd_check
    conf = Utils::Conf.new "config.yml"
    log = Utils::Log.new level: :info
    log.level = :debug if ENV["DEBUG"] == "1"
    docker = Utils::DockerClient.new URI(conf["docker_uri"]), log: log["docker"]
    checker = Checker.new conf[:mounts].map { Pathname _1 }, docker

    docker.get_json("/containers/json").each do |ctn|
      next unless ctn.fetch("Labels")["com.docker.compose.oneoff"] == "False"
      clog = log[Cmds.ctn_name ctn]
      clog.debug "checking"
      if (mnt, _ = checker.failed_mount? ctn, log: clog)
        clog[failed_mnt: mnt.basename].warn "restarting" do
          docker.container_restart ctn.fetch("Id")
        end
      end
    end
  end

  def self.ctn_name(ctn)
    case name = ctn.fetch("Names").fetch(0)
    when /^[\S]+_(.+)_\d+$/ then $1
    else name
    end
  end

  class Checker
    def initialize(dirs, docker)
      @dirs = dirs
      @docker = docker
    end

    def failed_mount?(ctn, log:)
      each_mounted_dir ctn do |mnt, dir|
        dlog = log[mnt: mnt.basename, dir: dir]
        ko = dlog.info "checking" do
          Timeout.timeout 10 do
            dir_failed_mount? ctn, dir
          end
        rescue Timeout::Error
          dlog.warn "timeout while checking"
          false
        end
        if ko
          return [mnt, dir]
        end
      end
      false
    end

    private def dir_failed_mount?(ctn, dir)
      @docker.container_exec(ctn.fetch("Id"), "ls", dir) { |_, out, err, thr|
        out = out.read
        err = err.read
        thr.value.success? or raise "failed to exec ls: #{err}"
        out
      }.split("\n").empty?
    end

    private def each_mounted_dir(ctn)
      @dirs.each do |dir|
        ctn.fetch("Mounts").each do |m|
          m.fetch("Type") == "bind" or next
          source = Pathname m.fetch("Source")
          if source.relative_path_from(dir).descend.first.to_s != ".."
            yield dir, Pathname(m.fetch("Destination"))
            break
          end
        end
      end
    end
  end # Checker
end

if $0 == __FILE__
  require 'metacli'
  MetaCLI.new(ARGV).run Cmds.new
end
