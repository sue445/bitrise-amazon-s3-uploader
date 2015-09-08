#

options = {
	ipa: ENV['ipa_path'],
	dsym: ENV['dsym_path'],
	app_slug: ENV['app_slug'],
	build_slug: ENV['build_slug'],
	access_key: ENV['aws_access_key'],
	secret_key: ENV['aws_secret_key'],
	bucket_name: ENV['bucket_name'],
	path_in_bucket: ENV['path_in_bucket'],
	acl: ENV['file_access_level']
}

p "Options: #{options}"


$formatted_output_file_path = ENV['BITRISE_STEP_FORMATTED_OUTPUT_FILE_PATH']

def puts_string_to_formatted_output(text)
	open($formatted_output_file_path, 'a') { |f|
		f.puts(text)
	}
end

def puts_section_to_formatted_output(section_text)
	open($formatted_output_file_path, 'a') { |f|
		f.puts
		f.puts(section_text)
		f.puts
	}
end

puts_section_to_formatted_output('# Amazon S3 Deploy')

def cleanup_before_error_exit(reason_msg=nil)
	puts " [!] Error: #{reason_msg}"
	puts_section_to_formatted_output("## Failed")
	unless reason_msg.nil?
		puts_section_to_formatted_output(reason_msg)
	end
	puts_section_to_formatted_output("Check the Logs for details.")
end

def s3_object_uri_for_bucket_and_path(bucket_name, path_in_bucket)
	return "s3://#{bucket_name}/#{path_in_bucket}"
end

def public_url_for_bucket_and_path(bucket_name, path_in_bucket)
	return "https://#{bucket_name}.s3.amazonaws.com/#{path_in_bucket}"
end

def export_output(out_key, out_value)
	IO.popen("envman add --key #{out_key.to_s}", 'r+') {|f|
		f.write(out_value.to_s)
		f.close_write
		f.read
	}
end


$s3cmd_config_path = "s3cfg.config"
def do_s3cmd(command_str)
	return system(%Q{s3cmd -c "#{$s3cmd_config_path}" #{command_str}})
end

status = "success"
begin
	# checks
	#
	# ipa
	raise "No IPA found to deploy. Terminating." unless File.exists?(options[:ipa])
	# dsym
	unless File.exists?(options[:dsym])
		options[:dsym] = nil
		puts_section_to_formatted_output "DSYM file not found. To generate debug symbols (dSYM) go to your Xcode Project's Settings - Build Settings - Debug Information Format and set it to DWARF with dSYM File."
	end
	# access_key
	raise "No AWS access key provided. Terminating." unless options[:access_key]
	# secret_key
	raise "No AWS secret key provided. Terminating." unless options[:secret_key]

	# AWS configs
	raise "Failed to set access keys" unless system(%Q{printf %"s\n" '[default]' "access_key = #{options[:access_key]}" "secret_key = #{options[:secret_key]}" > #{$s3cmd_config_path}})

	# define object path
	base_path_in_bucket = ""
	if options[:path_in_bucket]
		base_path_in_bucket = options[:path_in_bucket]
	else
		utc_timestamp = Time.now.utc.to_i
		base_path_in_bucket = "bitrise_#{options[:app_slug]}/#{utc_timestamp}_build_#{options[:build_slug]}"
	end

	puts " (i) Base path in Bucket: #{base_path_in_bucket}"

	# supported: private, public_read
	acl_arg = '--acl-public'
	if (options[:acl])
		case options[:acl]
		when 'public_read'
			acl_arg = '--acl-public'
		when 'private'
			acl_arg = '--acl-private'
		else
			raise "Invalid ACL option: #{options[:acl]}"
		end
	end

	# ipa upload
	puts_section_to_formatted_output "-> Uploading IPA"
	ipa_path_in_bucket = "#{base_path_in_bucket}/#{File.basename(options[:ipa])}"
	ipa_full_s3_path = s3_object_uri_for_bucket_and_path(options[:bucket_name], ipa_path_in_bucket)
	public_url_ipa = public_url_for_bucket_and_path(options[:bucket_name], ipa_path_in_bucket)
	#
	raise "Failed to upload IPA" unless do_s3cmd(%Q{put "#{options[:ipa]}" "#{ipa_full_s3_path}"})
	raise "Failed to set IPA ACL" unless do_s3cmd(%Q{setacl "#{ipa_full_s3_path}" #{acl_arg}})
	export_output('S3_DEPLOY_STEP_URL_IPA', public_url_ipa)
	puts_section_to_formatted_output "IPA upload success"

	# dsym upload
	if options[:dsym]
		puts_section_to_formatted_output "-> Uploading dSYM"
		dsym_path_in_bucket = "#{base_path_in_bucket}/#{File.basename(options[:dsym])}"
		dsym_full_s3_path = s3_object_uri_for_bucket_and_path(options[:bucket_name], dsym_path_in_bucket)
		public_url_dsym = public_url_for_bucket_and_path(options[:bucket_name], dsym_path_in_bucket)
		#
		raise "Failed to upload dSYM" unless do_s3cmd(%Q{put "#{options[:dsym]}" "#{dsym_full_s3_path}"})
		raise "Failed to set dSYM ACL" unless do_s3cmd(%Q{setacl "#{dsym_full_s3_path}" #{acl_arg}})

		export_output('S3_DEPLOY_STEP_URL_DSYM', public_url_dsym)
		puts_section_to_formatted_output "dSYM upload success"
	end

	ENV['S3_DEPLOY_STEP_URL_IPA'] = "#{public_url_ipa}"

	# plist generation - we have to run it after we have obtained the public url to the ipa
	system("sh ./gen_plist.sh")

	# plist upload
	plist_local_path = "Info.plist"

	if File.exists?(plist_local_path)
		puts_section_to_formatted_output "-> Uploading Info.plist"
		plist_path_in_bucket = "#{base_path_in_bucket}/Info.plist"
		plist_full_s3_path="s3://#{options[:bucket_name]}/#{plist_path_in_bucket}"
		public_url_plist = public_url_for_bucket_and_path(options[:bucket_name], plist_path_in_bucket)
		#
		raise "Failed to upload IPA" unless do_s3cmd(%Q{put "#{plist_local_path}" "#{plist_full_s3_path}"})
		raise "Failed to set Plist ACL" unless do_s3cmd(%Q{setacl "#{plist_full_s3_path}" #{acl_arg}})
		raise "Failed to remove Plist" unless system(%Q{rm "#{plist_local_path}"})
		puts_section_to_formatted_output "Info.plist upload success"
	else
		puts "NO PLIST :<"
	end

	export_output('S3_DEPLOY_STEP_URL_PLIST', public_url_plist)
	email_ready_link_url = "itms-services://?action=download-manifest&url=#{public_url_plist}"
	export_output('S3_DEPLOY_STEP_EMAIL_READY_URL', email_ready_link_url)

	puts_section_to_formatted_output("## Success")
	#
	puts_section_to_formatted_output("### File Access Level")
	puts_section_to_formatted_output("Specified File Access Level: **#{options[:acl]}**")
	#
	puts_section_to_formatted_output("### IPA")
	puts_section_to_formatted_output("[link](#{public_url_ipa})")
	puts_section_to_formatted_output("Raw:")
	puts_section_to_formatted_output("		#{public_url_ipa}")
	#
	puts_section_to_formatted_output("### DSYM")
	if options[:dsym]
		puts_section_to_formatted_output("[link](#{public_url_dsym})")
		puts_section_to_formatted_output("Raw:")
		puts_section_to_formatted_output("		#{public_url_dsym}")
	else
		puts_section_to_formatted_output %Q{DSYM file not found.
			To generate debug symbols (dSYM) go to your
			Xcode Project's Settings - `Build Settings - Debug Information Format`
			and set it to **DWARF with dSYM File**.}
	end
	#
	puts_section_to_formatted_output("### Plist")
	puts_section_to_formatted_output("[link](#{public_url_plist})")
	puts_section_to_formatted_output("Raw:")
	puts_section_to_formatted_output("		#{public_url_plist}")
	#
	puts_section_to_formatted_output("### Install link")
	puts_section_to_formatted_output("**open this link on an iOS device to install the app**")
	puts_section_to_formatted_output(%Q{<a href="#{email_ready_link_url}" target="_blank">link</a>})
	puts_section_to_formatted_output("Raw:")
	puts_section_to_formatted_output("		#{email_ready_link_url}")

rescue => ex
	status = "failed"
	cleanup_before_error_exit("#{ex}")
	exit 1
ensure
	export_output('S3_DEPLOY_STEP_STATUS', status)
	puts "status=" + status
	system("rm #{$s3cmd_config_path}")
end
