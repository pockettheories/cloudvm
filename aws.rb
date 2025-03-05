require 'Open3'
require 'logger'
require 'spicy-proton'

# TODO Make it possible to use an alternate profile
# TODO Make the instance type configurable

$logger = Logger.new($stdout)

$is_login_ensured = false

def ensure_aws_logged_in(profile=nil)
	if $is_login_ensured == true  # Ensure it happens only once, even if called multiple times
		return
	end

	profile_suffix = (profile.nil? ? [] : ['--profile', profile])
	aws_sts_cmd = ['aws', 'sts', 'get-caller-identity'] + profile_suffix

	outtxt, errtxt = Open3.capture3(*aws_sts_cmd)

	if outtxt.start_with? '{'
		$logger.debug 'Got JSON in caller identity'
	end

	if errtxt.include? 'could not be found'
		$logger.info 'AWS profile not found'
		raise 'Could not find profile ' + profile.to_s
	else
		$logger.info 'AWS profile found'
	end

	while errtxt.include? 'Error loading SSO Token' or errtxt.include? 'The SSO session associated with this profile has expired '
		$logger.info 'No valid SSO token'
		aws_login_cmd = ['aws', 'sso', 'login'] + profile_suffix
		outtxt, errtxt = Open3.capture3(*aws_login_cmd)
		if outtxt.include? 'Successfully logged into'
			$logger.info 'Login complete'
			break
		else
			$logger.info 'Login failed'
		end
	end
	$logger.info 'You are logged in'

	$is_login_ensured = true
end

def ec2_create
	ensure_aws_logged_in

	# Clean up from any previous activity

	ec2_destroy
	# key_id = `aws ec2 describe-key-pairs --key-names #{my_id} --query 'KeyPairs[0].KeyPairId' --output text 2> /dev/null`
	# if not key_id.empty?  # We dont know why it exists, so let's re-create it
	# 	system "aws ec2 delete-key-pair --key-name #{my_id}"
	# 	File.delete 'my-key-pair.pem'
	# 	sleep 8
	# end

	# Generate a new ID

	my_id = Spicy::Proton.pair
	File.write('my_id', my_id)

	# Create a key pair

	%x[aws ec2 create-key-pair --key-name #{my_id} --key-type rsa --key-format pem --query "KeyMaterial" --output text > my-key-pair.pem]
	`chmod 400 my-key-pair.pem`

	# Find an image AMI

	# TODO: Returns Ubuntu 22.04, but not 24.04
	ami_id = `aws ec2 describe-images --owners amazon --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-*" "Name=architecture,Values=x86_64" --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text`.strip

	# Create an instance

	aws_ec2_created_out = %x[aws ec2 run-instances --image-id #{ami_id} --instance-type t3.small --key-name #{my_id} --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=#{my_id}}]']

	# Check status and connect
	# TODO
end

def ec2_connect
	ensure_aws_logged_in
	my_id = File.read('my_id')

	# Look for stopped instances and start if needed

	pub_ip = `aws ec2 describe-instances --filters "Name=tag:Name,Values=#{my_id}" --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Association.PublicIp' --output text`.strip
	secu_grp_id = `aws ec2 describe-instances --filters "Name=tag:Name,Values=#{my_id}" --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text`.strip

	my_ip = `curl -s -4 ifconfig.me`.strip
	system "aws ec2 authorize-security-group-ingress --group-id #{secu_grp_id} --protocol tcp --port 22 --cidr #{my_ip}/32  > /dev/null 2>&1"  # Ignore the error that the whitelist already exists

	exec("ssh -o StrictHostKeyChecking=no -i my-key-pair.pem ubuntu@#{pub_ip}")
end

def ec2_stop
	ensure_aws_logged_in
	my_id = File.read('my_id')

	instance_id = `aws ec2 describe-instances --filters "Name=tag:Name,Values=#{my_id}" --query 'Reservations[0].Instances[0].InstanceId' --output text`.strip
	system "aws ec2 stop-instances --instance-ids #{instance_id} > /dev/null 2>&1"
end

def ec2_status
	ensure_aws_logged_in
	my_id = File.read('my_id')

	status = `aws ec2 describe-instances --filter 'Name=tag:Name,Values=#{my_id}' --query 'Reservations[0].Instances[0].State.Name' --output text`
	puts status
end

def ec2_start
	ensure_aws_logged_in
	my_id = File.read('my_id')

	instance_id = `aws ec2 describe-instances --filters "Name=tag:Name,Values=#{my_id}" --query 'Reservations[0].Instances[0].InstanceId' --output text`.strip
	system "aws ec2 start-instances --instance-ids #{instance_id} > /dev/null 2>&1"
end

$is_destroy_done = false

def ec2_destroy
	if $is_destroy_done == true
		return
	end

	ensure_aws_logged_in
	if File.exist? 'my_id'
		my_id = File.read('my_id')

		instance_id = `aws ec2 describe-instances --filters "Name=tag:Name,Values=#{my_id}" --query 'Reservations[0].Instances[0].InstanceId' --output text`.strip
		if not (instance_id.empty? or instance_id == 'None')
			system "aws ec2 terminate-instances --instance-ids #{instance_id} > /dev/null 2>&1"
			sleep 10
		end

		key_id = `aws ec2 describe-key-pairs --key-names #{my_id} --query 'KeyPairs[0].KeyPairId' --output text 2> /dev/null`
		if not (key_id.empty? or key_id == 'None')
			system "aws ec2 delete-key-pair --key-name #{my_id} > /dev/null 2>&1"
			File.delete 'my-key-pair.pem'
			sleep 10
		end

		File.delete 'my_id'
	end

	$is_destroy_done = true
end

# ruby -r ./aws.rb -e 'ec2_connect'
