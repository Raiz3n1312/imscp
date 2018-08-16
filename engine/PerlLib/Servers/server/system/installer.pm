=head1 NAME

 Servers::server::system::installer - i-MSCP system server implementation

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2018 by Laurent Declercq <l.declercq@nuxwin.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package Servers::server::system::installer;

use strict;
use warnings;
use DateTime::TimeZone;
use iMSCP::Boolean;
use iMSCP::Database;
use iMSCP::Debug qw/ debug error /;
use iMSCP::Dialog::InputValidation qw/ isOneOfStringsInList isStringNotInList isValidIpAddr isValidHostname isValidIpAddr isValidTimezone /;
use iMSCP::Execute qw/ execute /;
use iMSCP::EventManager;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::Net;
use Net::LibIDN qw/ idn_to_ascii idn_to_unicode /;
use LWP::Simple qw/ get /;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP system server implementation

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners( $eventManager )

 Register setup event listeners

 Param iMSCP::EventManager $eventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
    my ( $self, $eventManager ) = @_;

    $eventManager->register(
        'beforeSetupDialog',
        sub {
            push @{ $_[0] },
                sub { $self->askForServerHostname( @_ ) },
                sub { $self->askForServerIPv6Support( @_ ) },
                sub { $self->askForServerPrimaryIP( @_ ) },
                sub { $self->askForServerTimezone( @_ ) };
            0;
        },
        # Register the dialogs with a hightest priority to show them before any
        # other server/package dialog
        999
    );
}

=item askForServerHostname( $dialog )

 Ask for server hostname

 Param iMSCP::Dialog $dialog
 Return int 0 (NEXT), 30 (BACK), 50 (ESC)

=cut

sub askForServerHostname
{
    my ( undef, $dialog ) = @_;

    my $hostname = ::setupGetQuestion( 'SERVER_HOSTNAME' );
    $iMSCP::Dialog::InputValidation::lastValidationError = '';

    if ( isOneOfStringsInList( iMSCP::Getopt->reconfigure, [ 'system', 'system_hostname', 'hostnames', 'alternatives', 'all' ] )
        || !isValidHostname( $hostname )
    ) {
        chomp( $hostname = $hostname || `hostname --fqdn 2>/dev/null` || '' );
        $hostname = idn_to_unicode( $hostname, 'utf-8' );

        do {
            ( my $rs, $hostname ) = $dialog->inputbox( <<"EOF", $hostname );
$iMSCP::Dialog::InputValidation::lastValidationError
Please enter your server fully qualified hostname:
\\Z \\Zn
EOF
            return $rs unless $rs < 30;
        } while !isValidHostname( $hostname );
    }

    ::setupSetQuestion( 'SERVER_HOSTNAME', idn_to_ascii( $hostname, 'utf-8' ));
    0;
}

=item askIPv6Support( $dialog )

 Ask for IPv6 support

 Param iMSCP::Dialog $dialog
 Return int 0 (NEXT), 20 (SKIP) 30 (BACK) or 50 (ESC)

=cut

sub askForServerIPv6Support
{
    my ( undef, $dialog ) = @_;

    unless ( -f '/proc/net/if_inet6' ) {
        ::setupSetQuestion( 'IPV6_SUPPORT', 'no' );
        return 20;
    }

    my $value = ::setupGetQuestion( 'IPV6_SUPPORT' );

    if ( isOneOfStringsInList( iMSCP::Getopt->reconfigure, [ 'system', 'system_ipv6', 'alternatives', 'all' ] )
        || isStringNotInList( $value, 'yes', 'no' )
    ) {
        my $rs = $dialog->yesno( <<"EOF", $value eq 'no', TRUE );

Do you want to enable IPv6 support?

If you say 'no', IPv6 support will be disabled globally. You'll not be able to add new IPv6 addresses and services will be configured to listen on IPv4 only.
EOF
        return $rs unless $rs < 30;
        $value = $rs ? 'no' : 'yes';
    }

    ::setupSetQuestion( 'IPV6_SUPPORT', $value );
    0;
}

=item askForServerPrimaryIP( $dialog )

 Ask for server primary IP

 Param iMSCP::Dialog $dialog
 Return int 0 (NEXT), 30 (BACK), 50 (ESC)

=cut

sub askForServerPrimaryIP
{
    my ( undef, $dialog ) = @_;

    my @ipList = ( ::setupGetQuestion( 'IPV6_SUPPORT' ) eq 'yes'
        ? grep ( isValidIpAddr( $_, qr/(?:PRIVATE|UNIQUE-LOCAL-UNICAST|PUBLIC|GLOBAL-UNICAST)/ ), iMSCP::Net->getInstance()->getAddresses() )
        : grep ( isValidIpAddr( $_, qr/(?:PRIVATE|PUBLIC)/ ), iMSCP::Net->getInstance()->getAddresses() ),
        'None'
    );
    @ipList = sort @ipList or die( "Couldn't get list of server IP addresses. At least one IP address must be configured." );

    my $lanIP = ::setupGetQuestion( 'BASE_SERVER_IP', iMSCP::Getopt->preseed ? 'None' : '' );
    $lanIP = 'None' if $lanIP eq '0.0.0.0';

    my $wanIP = ::setupGetQuestion( 'BASE_SERVER_PUBLIC_IP', ( iMSCP::Getopt->preseed ? do {
        chomp( my $wanIP = get( 'https://api.ipify.org/' ) || get( 'https://ipinfo.io/ip/' ) || $lanIP );
        $wanIP;
    } : '' ));

    Q1:
    if ( isOneOfStringsInList( iMSCP::Getopt->reconfigure, [ 'system', 'system_primary_ip', 'alternatives', 'all' ] )
        || isStringNotInList( $lanIP, @ipList )
    ) {
        do {
            my %choices;
            @choices{@ipList} = @ipList;
            ( my $rs, $lanIP ) = $dialog->radiolist( <<"EOF", \%choices, ( grep ( $lanIP eq $_, @ipList ) )[0] || $ipList[0] );

Please select your server primary IP address:

The \\Zb'None'\\ZB option means that i-MSCP will configure the services to listen on all interfaces.
This option is more suitable for Cloud computing services such as Scaleway and Amazon EC2, or in the case of a dynamic IP address obtained through DHCP.
\\Z \\Zn
EOF
            return $rs unless $rs < 30;
            $lanIP = '0.0.0.0' if $lanIP eq 'None';
        } while !isValidIpAddr( $lanIP );


    } elsif ( $lanIP eq 'None' ) {
        $lanIP = '0.0.0.0';
    }

    ::setupSetQuestion( 'BASE_SERVER_IP', $lanIP );

    $iMSCP::Dialog::InputValidation::lastValidationError = '';

    Q2:
    if ( isOneOfStringsInList( iMSCP::Getopt->reconfigure, [ 'system', 'system_primary_ip', 'alternatives', 'all' ] ) || !isValidIpAddr( $wanIP ) ) {
        do {
            if ( !length $wanIP || $wanIP eq 'None' ) {
                $iMSCP::Dialog::InputValidation::lastValidationError = '';
                chomp( $wanIP = get( 'https://api.ipify.org/' ) || get( 'https://ipinfo.io/ip/' ) || $lanIP );
                $wanIP = '' if $wanIP eq '0.0.0.0';
            }

            ( my $rs, $wanIP ) = $dialog->inputbox( <<"EOF", $wanIP );
$iMSCP::Dialog::InputValidation::lastValidationError
Please enter your public IP address (leave empty for default):
\\Z \\Zn
EOF
            goto Q1 if $rs == 30;
            return $rs if $rs == 50;
        } while !isValidIpAddr( $wanIP );
    }

    ::setupSetQuestion( 'BASE_SERVER_PUBLIC_IP', $wanIP );

    if ( isOneOfStringsInList( iMSCP::Getopt->reconfigure, [ 'system', 'system_primary_ip', 'all' ] ) ) {
        my $rs = $dialog->yesno( <<"EOF", TRUE, TRUE );

Do you want to replace all IP addresses currently set with the new primary IP address?

Be aware that this will reset resellers and clients IP addresses.
EOF
        goto Q2 if $rs == 30;
        return $rs if $rs == 50;
        ::setupSetQuestion( 'REPLACE_CLIENTS_IP_WITH_BASE_SERVER_IP', !!!$rs );
    } else {
        ::setupSetQuestion( 'REPLACE_CLIENTS_IP_WITH_BASE_SERVER_IP', FALSE );
    }

    0;
}

=item askForServerTimezone( $dialog )

 Ask for server timezone

 Param iMSCP::Dialog $dialog
 Return int 0 (NEXT), 30 (BACK), 50 (ESC)

=cut

sub askForServerTimezone
{
    my ( undef, $dialog ) = @_;

    my $value = ::setupGetQuestion( 'TIMEZONE', iMSCP::Getopt->preseed ? DateTime::TimeZone->new( name => 'local' )->name() : '' );
    $iMSCP::Dialog::InputValidation::lastValidationError = '';

    if ( isOneOfStringsInList( iMSCP::Getopt->reconfigure, [ 'system', 'system_timezone', 'alternatives', 'all' ] ) || !isValidTimezone( $value ) ) {
        do {
            ( my $rs, $value ) = $dialog->inputbox( <<"EOF", $value || DateTime::TimeZone->new( name => 'local' )->name());
$iMSCP::Dialog::InputValidation::lastValidationError
Please enter your timezone:
\\Z \\Zn
EOF
            return $rs unless $rs < 30;
        } while !isValidTimezone( $value );
    }

    ::setupSetQuestion( 'TIMEZONE', $value );
    0;
}

=item preinstall( )

 Process preinstall tasks

 Return int 0 on success, other on failure

=cut

sub preinstall
{
    my ( $self ) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeSetupKernel' );
    return $rs if $rs;

    if ( -f "$::imscpConfig{'SYSCTL_CONF_DIR'}/imscp.conf" ) {
        # Don't catch any error here to avoid permission denied error on some
        # vps due to restrictions set by provider
        execute( "$::imscpConfig{'CMD_SYSCTL'} -p $::imscpConfig{'SYSCTL_CONF_DIR'}/imscp.conf", \my $stdout, \my $stderr );
        debug( $stdout ) if $stdout;
        debug( $stderr ) if $stderr;
    }

    $self->{'eventManager'}->trigger( 'afterSetupKernel' );

    0;
}

=item install( )

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my ( $self ) = @_;

    my $rs = $self->_setupHostname();
    $rs ||= $self->_setupPrimaryIP();
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize instance

 Return Servers::server::system::installer

=cut

sub _init
{
    my ( $self ) = @_;

    $self->{'eventManager'} = iMSCP::EventManager->getInstance();
    $self;
}

=item _setupHostname( )

 Setup server hostname

 Return int 0 on success, other on failure

=cut

sub _setupHostname
{
    my ( $self ) = @_;

    my $hostname = ::setupGetQuestion( 'SERVER_HOSTNAME' );
    my $lanIP = ::setupGetQuestion( 'BASE_SERVER_IP' );
    $lanIP = '127.0.1.1' if $lanIP eq '0.0.0.0';

    my $rs = $self->{'eventManager'}->trigger( 'beforeSetupServerHostname', \$hostname, \$lanIP );
    return $rs if $rs;

    my $machine = ( split /\./, $hostname )[0];

    my $file = iMSCP::File->new( filename => '/etc/hosts' );
    $rs = $file->copyFile( '/etc/hosts.bkp' ) unless -f '/etc/hosts.bkp';
    return $rs if $rs;

    my $content = <<"EOF";
127.0.0.1\t localhost.localdomain localhost
$lanIP\t$hostname\t$machine

# The following lines are desirable for IPv6 capable hosts    
::1 localhost  ip6-localhost   ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts

EOF
    $file->set( $content );

    $rs = $file->save();
    $rs ||= $file->owner( $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'} );
    $rs ||= $file->mode( 0644 );
    return $rs if $rs;

    $file = iMSCP::File->new( filename => '/etc/hostname' );
    $file->set( $hostname );

    $rs = $file->save();
    $rs ||= $file->owner( $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'} );
    $rs ||= $file->mode( 0644 );
    return $rs if $rs;

    $file = iMSCP::File->new( filename => '/etc/mailname' );
    $file->set( $hostname );

    $rs = $file->save();
    $rs ||= $file->owner( $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'} );
    $rs ||= $file->mode( 0644 );
    return $rs if $rs;

    $rs = execute( 'hostname -F /etc/hostname', \my $stdout, \my $stderr );
    debug( $stdout ) if $stdout;
    error( $stderr || "Couldn't set server hostname" ) if $rs;
    $rs ||= $self->{'eventManager'}->trigger( 'afterSetupServerHostname' );
}

=item _setupPrimaryIP( )

 Setup server primary IP

 Return int 0 on success, other on failure

=cut

sub _setupPrimaryIP
{
    my ( $self ) = @_;

    my $primaryIP = ::setupGetQuestion( 'BASE_SERVER_IP' );
    my $rs = $self->{'eventManager'}->trigger( 'beforeSetupPrimaryIP', $primaryIP );
    return $rs if $rs;

    local $@;
    eval {
        my $netCard = ( $primaryIP eq '0.0.0.0' ) ? 'any' : iMSCP::Net->getInstance()->getAddrDevice( $primaryIP );
        defined $netCard or die( sprintf( "Couldn't find network card for the '%s' IP address", $primaryIP ));

        my $db = iMSCP::Database->factory();
        my $oldDbName = $db->useDatabase( ::setupGetQuestion( 'DATABASE_NAME' ));

        my $dbh = $db->getRawDb();
        local $dbh->{'RaiseError'} = TRUE;

        $dbh->selectrow_hashref( 'SELECT 1 FROM server_ips WHERE ip_number = ?', undef, $primaryIP )
            ? $dbh->do( 'UPDATE server_ips SET ip_card = ? WHERE ip_number = ?', undef, $netCard, $primaryIP )
            : $dbh->do(
            'INSERT INTO server_ips (ip_number, ip_card, ip_config_mode, ip_status) VALUES(?, ?, ?, ?)', undef, $primaryIP, $netCard, 'manual', 'ok'
        );

        if ( ::setupGetQuestion( 'REPLACE_CLIENTS_IP_WITH_BASE_SERVER_IP' ) ) {
            my $resellers = $self->{'dbh'}->selectall_arrayref( 'SELECT reseller_id, reseller_ips FROM reseller_props', { Slice => {} } );

            if ( @{ $resellers } ) {
                my $primaryIpID = $self->{'dbh'}->selectrow_array( 'SELECT ip_id FROM server_ips WHERE ip_number = ?', undef, $primaryIP );

                # FIXME: Instead of replacing all IP addresses by the new primary IP addresses by closing
                # eyes, it could be best to only replace those that are orphaned:
                #  1. Find IP addresses that are no longer available in the server_ips table.
                #  2. Replace IP addresses found by the new primary IP addresses, with uniqueness in mind
                eval {
                    $dbh->begin_work();
                    for my $reseller ( @{ $resellers } ) {
                        my @ipIDS = split( ';', $reseller->{'reseller_ips'} );
                        next if grep ($_ eq $primaryIpID, @ipIDS );
                        push @ipIDS, $primaryIpID;
                        $dbh->do( 'UPDATE reseller_props SET reseller_ips = ? WHERE reseller_id = ?', undef, join( ',', @ipIDS ));
                    }

                    $dbh->do( 'UPDATE client_props SET client_ips = ?, domain_ips = ?', undef, $primaryIpID, $primaryIpID );
                    $dbh->do( 'UPDATE domain SET  domain_ips = ?', undef, $primaryIpID, $primaryIpID );
                };
                if ( $@ ) {
                    $dbh->rollback();
                    die;
                }
            }
        }

        $db->useDatabase( $oldDbName ) if length $oldDbName;
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $self->{'eventManager'}->trigger( 'afterSetupPrimaryIP', $primaryIP );
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
