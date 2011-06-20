#!/usr/bin/env ruby 
#
# HAProxy control script to start, stop, restart, configcheck, etc, as 
# well as communicate to the stats socket.
#
# See https://github.com/flores/haproxyctl/README
#
# This line here is just for Redhat users who like "service haproxyctl blah"
# chkconfig: 2345 80 30
# description: HAProxy is a fast and reliable load balancer for UNIX systems
#	HAProxyctl is an easy way to do init shit and talk to its stats socket
#

# variables you may actually need to change

# change this if the file is elsewhere
@config	= "/etc/haproxy/haproxy.cfg" 

# grab the statistics socket from above
@socket	= `awk '/stats socket/ {print $3}' #{@config}`.chomp ||
  raise("Expecting \'stats socket <UNIX_socket_path>\' in #{@config}")

# where haproxy lives and pid (either in conf or static location)
@exec    = `which haproxy`.chomp || raise("Where the F is haproxy?")
@pid	= `awk '/pidfile/ {print $2}' #{@config}` 
unless ( @pid =~ /\w+/ )
	@pid = "/var/run/haproxy.pid"
end

# the functions

def start()
	puts "starting haproxy..."
	system("#{@exec} -f #{@config} -D -p #{@pid}")
	newpidof = `pidof haproxy`.chomp
	if ( newpidof =~ /\d+/ )
		puts "haproxy is running on pid #{newpidof}"
		return true
	else
		puts "error.  haproxy did not start!"
		return nil
	end
end

def stop(pid)
	if ( pid )
		puts "stopping haproxy on pid #{pid}..."
		system("kill #{pid}") || system("killall haproxy")
		puts "... stopped"
	else
		puts "haproxy is not running!"
	end
end

def check_running()
	pidof	= `pidof haproxy`.chomp
	if ( pidof =~ /^\d+$/ )
		return pidof
	else
		return nil
	end
end

def reload(pid)
	if ( pid )
		puts "gracefully stopping connections on pid #{pid}..."
		system("#{@exec} -f #{@config} -sf #{pid}")
		puts "checking if connections still alive on #{pid}..."
		nowpid = check_running() 
		while ( pid == nowpid )
			puts "still haven't killed old pid.  
                          waiting 2s for existing connections to die... 
                          (ctrl+c to stop this check)"
			sleep 2
			nowpid = check_running() || 0
		end
		puts "reloaded haproxy on pid #{nowpid}"
	else
		puts "haproxy is not running!"
	end
end			
	
def unixsock(command)
	require 'socket'

	output=[]
	
	ctl=UNIXSocket.open(@socket)
	ctl.puts "#{command}"
	while (line = ctl.gets) do
		unless ( line =~ /Unknown command/ )
			output << line
		end
	end
	ctl.close

	return output
end


# the help / no argument output includes the help output from haproxy's stats socket
if ( ARGV.length != 1 || ARGV[0] =~ /help/ )
	puts "usage: #{$0} <argument> 
where argument can be:
  start		 : start haproxy unless it is already running
  stop		 : stop an existing haproxy 
  restart	 : immediately shutdown and restart
  reload	 : gracefully terminate existing connections, reload #{@config}
  status	 : is haproxy running?  on what ports per lsof?
  configcheck    : check #{@config}
  nagios	 : nagios-friendly status for running process and listener
  cloudkick      : cloudkick.com-friendly status and metric for connected users
  show health    : show status of all frontends and backend servers
  enable all server
		 : re-enable a server previously in maint mode on multiple backends
  disable all server
		 : disable a server from every backend it exists
  enable all EXCEPT server
		 : like 'enable all', but re-enables every backend except for <server>
  disable all EXCEPT server
		 : like 'disable all', but disables every backend except for <server>"
end

pidof = check_running()

argument = case ARGV[0]

	when "start"
		if ( pidof )
			raise("haproxy is already running on pid #{pidof}!")
		else
			start()
		end

	when "stop"
		stop(check_running())

	when "restart"
		if ( pidof )
			stop(pidof)
			stillpidof = check_running()
			while ( stillpidof == pidof )
				puts "still haven't killed old pid.  waiting 3s for existing connections to die... (ctrl+c to stop)"
                                sleep 3
                                stillpidof = check_running() || 0
			end
			start()
		else
			puts "haproxy was not running.  starting..."
			start()
		end

	when "reload"
		if ( pidof )
			reload(pidof)
		else
			puts "haproxy not running.  starting..."
			start()
		end

	when "status"
		if ( pidof )
			puts "haproxy is running on pid #{pidof}.\nthese ports are used and guys are connected:"
			system("lsof -ln -i |awk \'$2 ~ /#{pidof}/ {print $8\" \"$9}\'")
		else
			puts "haproxy is not running"
		end

	when "configcheck"
		puts `#{@exec} -c -f #{@config}`

	when "nagios"
		if ( pidof )
			puts "OK"
			exit
		else
			puts "CRITICAL: HAProxy is not running!"
			exit(2)
		end

	when "cloudkick"
		if ( pidof )
			puts "status ok haproxy is running"
			conn = `lsof -ln -i |grep -c #{pidof}`.chomp.to_i
			# removes the listener
			conn = conn - 1
			puts "metric connections int #{conn}"
			status=unixsock("show stat")
			status.each do |line|
				line = line.split(',')
				if (line[0] !~ /^#/)
                        		host = "#{line[0]}_#{line[1]}"
		                        puts "metric #{host}_request_rate int #{line[47]}" if line[47].to_i > 0
                		        puts "metric #{host}_total_requests gauge #{line[49]}" if line[49].to_i > 0
		                        puts "metric #{host}_health_check_duration int #{line[35]}" if line[35].to_i > 0
                		        puts "metric ${host}_current_queue int #{line[3]}" if line[3].to_i > 0
                		end
			end
		else
			puts "status err haproxy is not running!"
		end

	when "show health"
		status=unixsock("show stat")
		status.each do |line|
			data = line.split(',')
			printf "%-15s %-20s %-7s %-3s\n", data[0], data[1], data[17], data[18]
		end
	when /disable all EXCEPT (.+)/
		servername=$1
                status=unixsock("show stat")
		backend = status.grep(/#{servername}/)
                backend.each do |line|
                        backend_group = line.split(',')
			status.each do |pool|
				data = pool.split(',')
				if ( (data[0] == backend_group[0]) && ( data[1] !~ /#{servername}|BACKEND|FRONTEND/ ) && ( data[17] = 'UP' ) )
                                	unixsock("disable server #{data[0]}/#{data[1]}")
                        	end
			end
                end
	when /disable all (.+)/
		servername=$1
		status=unixsock("show stat")
		status.each do |line|
			data = line.split(',')
			if ( ( data[1] = servername ) && ( data[17] = 'UP' ) )
				unixsock("disable server #{data[0]}/#{servername}")
			end
		end
        when /enable all EXCEPT (.+)/
                servername=$1
                status=unixsock("show stat")
                backend = status.grep(/#{servername}/)
                backend.each do |line|
                        backend_group = line.split(',')
                        status.each do |pool|
                                data = pool.split(',')
                                if ( (data[0] == backend_group[0]) && ( data[1] !~ /#{servername}|BACKEND|FRONTEND/ ) && ( data[17] =~ /Down|MAINT/i ) )
                                        unixsock("enable server #{data[0]}/#{data[1]}")
                                end
                        end
                end
	when /enable all (.+)/
		servername=$1
		status=unixsock("show stat")
		status.each do |line|
			data = line.split(',')
			if ( ( data[1] = servername ) && ( data[17] =~ /Down|MAINT/i ) )
				unixsock("enable server #{data[0]}/#{servername}")
			end
		end
	else
		puts unixsock( "#{ARGV}" )

end
