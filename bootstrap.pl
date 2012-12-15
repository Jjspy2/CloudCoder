#! /usr/bin/perl -w

use strict;
use FileHandle;

# Bootstrap CloudCoder on an Ubuntu server

my $program = $0;
#print "program=$program\n";
#exit 0;

my $dryRun = 1;

my $mode = 'start';

if (scalar(@ARGV) > 0) {
	$mode = shift @ARGV;
}

if ($mode eq 'start') {
	Start();
} elsif ($mode eq 'step2') {
	Step2();
} else {
	die "Unknown mode: $mode\n";
}

sub Start {
	print <<"GREET";
Welcome to the CloudCoder bootstrap script.

By running this script, you will create a basic CloudCoder
installation on a server running Ubuntu Linux.

Make sure to run this script from a user account that has
permission to run the "sudo" command.  If you see the
following prompt:

  sudo password>>

then you will need to type the account password and press
enter.
GREET
	
	my $readyToStart = ask("\nReady to start? (yes/no)");
	exit 0 if ((lc $readyToStart) ne 'yes');
	
	print "\nFirst, please enter some configuration information...\n\n";
	
	# Get minimal required configuration information
	my $ccUser = ask("What username do you want for your CloudCoder account?");
	my $ccPasswd = ask("What password do you want for your CloudCoder account?");
	my $ccFirstName = ask("What is your first name?");
	my $ccLastName = ask("What is your last name?");
	my $ccEmail = ask("What is your email address?");
	my $ccWebsite = ask("What is the URL of your personal website?");
	my $ccMysqlRootPasswd = ask("What password do you want for the MySQL root user?");
	my $ccMysqlCCPasswd = ask("What password do you want for the MySQL cloudcoder user?");
	my $ccHostname = ask("What is the hostname of this server?");
	
	# ----------------------------------------------------------------------
	# Install/configure required packages
	# ----------------------------------------------------------------------
	print "\n";
	section("Installing required packages");
	RunAdmin(
		env => { 'DEBIAN_FRONTEND' => 'noninteractive' },
		cmd => ["apt-get", "update"]
	);
	# Determine which mysql-server version we will use
	my $mysqlVersion = FindMysqlVersion();
	print "Mysql version is $mysqlVersion\n";

	# Configure mysql root password so that no user interaction
	# will be required when installing packages.
	DebconfSetSelections("mysql-server-$mysqlVersion", "mysql-server/root_password", "password $ccMysqlRootPasswd");
	DebconfSetSelections("mysql-server-$mysqlVersion", "mysql-server/root_password_again", "password $ccMysqlRootPasswd");

	RunAdmin(
		env => { 'DEBIAN_FRONTEND' => 'noninteractive' },
		cmd => ["apt-get", "-y", "install", "openjdk-6-jdk", "mysql-client-$mysqlVersion",
			"mysql-server-$mysqlVersion", "apache2"]
	);
	RunAdmin(cmd => ["mysqladmin", "-u", "root", "password", $ccMysqlRootPasswd]);
	
	# ----------------------------------------------------------------------
	# Configure MySQL
	# ----------------------------------------------------------------------
	print "\n";
	section("Configuring MySQL");
	Run("mysql", "--user=root", "--pass=$ccMysqlRootPasswd",
		"--execute=create user 'cloudcoder'\@'localhost' identified by '$ccMysqlCCPasswd'");
	Run("mysql", "--user=root", "--pass=$ccMysqlRootPasswd",
		"--execute=grant all on cloudcoderdb.* to 'cloudcoder'\@'localhost'");
	
	# ----------------------------------------------------------------------
	# Create cloud user
	# ----------------------------------------------------------------------
	RunAdmin(
		cmd => [ 'adduser', '--disabled-password', '--home', '/home/cloud', '--gecos', '', 'cloud' ]
	);

	# Configure apache2
	RunAdmin(cmd => ['a2enmod', 'proxy']);
	RunAdmin(cmd => ['a2enmod', 'proxy_http']);

	# Continue as the cloud user to complete the installation
	# TODO
	Run("cp", $0, "/tmp/bootstrap.pl");
	Run("chmod", "a+x", "/tmp/bootstrap.pl");
	RunAdmin(
		asUser => 'cloud',
		cmd => ["/tmp/bootstrap.pl", "step2",
			"ccUser=$ccUser,ccPassword=$ccPasswd,ccFirstName=$ccFirstName," .
			"ccLastName=$ccLastName,ccEmail=$ccEmail,ccWebsite=$ccWebsite," .
			"ccMysqlCCPasswd=$ccMysqlCCPasswd,ccHostname=$ccHostname"]);
}

sub Step2 {
	# Complete the installation running as the cloud user
	my $whoami = `whoami`;
	chomp $whoami;
	print "Step2: running as $whoami\n";
}

sub ask {
	my ($question, $defval) = @_;

	print "$question\n";
	if (defined $defval) {
		print "[default: $defval] ";
	}
	print "==> ";

	my $value = <STDIN>;
	chomp $value;

	if ((defined $defval) && $value =~ /^\s*$/) {
		$value = $defval;
	}

	return $value;
}

sub section {
	my ($name) = @_;
	print "#" x 72, "\n";
	print " >>> $name <<<\n";
	print "#" x 72, "\n\n";
}

sub RunAdmin {
	my %params = @_;
	die "RunAdmin with no command\n" if (! exists $params{'cmd'});

	# Set environment variables (saving previous values)
	my %origEnv = ();
	if (exists $params{'env'}) {
		foreach my $var (keys %{$params{'env'}}) {
			my $val = $params{'env'}->{$var};
			$origEnv{$var} = $val;
			$ENV{$var} = $val;
		}
	}

	my @sudo = ('sudo', '-p', 'sudo password>> ');
	my @cmd;
	if (exists $params{'asUser'}) {
		@cmd = (@sudo, '-u', $params{'asUser'}, @{$params{'cmd'}});
	} else {
		@cmd = (@sudo, @{$params{'cmd'}});
	}

	my $result;
	if ($dryRun) {
		print "cmd: ", join(' ', @cmd), "\n";
		$result = 1;
	} else {
		$result = system(@cmd)/256 == 0;
	}

	# Restore previous values
	foreach my $var (keys %origEnv) {
		$ENV{$var} = $origEnv{$var};
	}

	die "Admin command $cmd[3] failed\n" if (!$result);
}

sub Run {
	if ($dryRun) {
		print "cmd: ", join(' ', @_), "\n";
	} else {
		system(@_)/256 == 0 || die "Command $_[0] failed\n";
	}
}

sub FindMysqlVersion {
	my $fh = new FileHandle("apt-cache search mysql-server|");
	my $version;
	while (<$fh>) {
		chomp;
		if (/^mysql-server-(\d+(\.\d+)*)\s/) {
			$version = $1;
			last;
		}
	}
	$fh->close();

	die "Couldn't not find mysql version\n" if (!defined $version);
	return $version;
}

sub DebconfSetSelections {
	my ($package, $prop, $value) = @_;
	my $cmd = "echo '$package $prop $value' | sudo -p 'sudo password>> ' debconf-set-selections";
	if ($dryRun) {
		print "cmd: $cmd\n";
	} else {
		system($cmd)/256 == 0 || die "Couldn't run debconf-set-selections\n";
	}
}

# vim:ts=2:
