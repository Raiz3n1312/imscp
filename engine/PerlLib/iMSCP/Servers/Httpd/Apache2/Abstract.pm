=head1 NAME

 iMSCP::Servers::Httpd::Apache2::Abstract - i-MSCP Apache2 server abstract implementation

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

package iMSCP::Servers::Httpd::Apache2::Abstract;

use strict;
use warnings;
use Array::Utils qw/ unique /;
use autouse 'Date::Format' => qw/ time2str /;
use autouse 'iMSCP::Crypt' => qw/ ALNUM decryptRijndaelCBC randomStr /;
use autouse 'iMSCP::Dialog::InputValidation' => qw/ isOneOfStringsInList isStringInList /;
use Carp qw/ croak /;
use Class::Autouse qw/ :nostat iMSCP::Database iMSCP::Servers::Sqld /;
use File::Basename;
use File::Spec;
use File::Temp;
use iMSCP::Debug qw/ debug error getMessageByType /;
use iMSCP::Dir;
use iMSCP::Execute qw/ execute /;
use iMSCP::Ext2Attributes qw/ setImmutable clearImmutable isImmutable /;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::Mount qw/ mount umount isMountpoint addMountEntry removeMountEntry /;
use iMSCP::Net;
use iMSCP::Rights;
use iMSCP::SystemUser;
use iMSCP::TemplateParser qw/ processByRef replaceBlocByRef /;
use Scalar::Defer;
use parent qw/ iMSCP::Servers::Httpd /;

my $TMPFS = lazy
    {
        my $tmpfs = iMSCP::Dir->new( dirname => "$main::imscpConfig{'IMSCP_HOMEDIR'}/tmp/apache2_tmpfs" )->make( { umask => 0027 } );
        return $tmpfs if isMountpoint( $tmpfs );

        mount(
            {
                fs_spec         => 'tmpfs',
                fs_file         => $tmpfs,
                fs_vfstype      => 'tmpfs',
                fs_mntops       => 'noexec,nosuid,size=32m',
                ignore_failures => 1 # Ignore failures in case tmpfs isn't supported/allowed
            }
        );

        $tmpfs;
    };

=head1 DESCRIPTION

 i-MSCP Apache2 server abstract implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners()

 See iMSCP::Servers::Abstract::RegisterSetupListeners()

=cut

sub registerSetupListeners
{
    my ($self) = @_;

    $self->{'eventManager'}->registerOne(
        'beforeSetupDialog',
        sub {
            push @{$_[0]}, sub { $self->askForApache2MPM( @_ ) };
            0;
        },
        $self->getPriority()
    );
}

=item askForApache2MPM( \%dialog )

 Ask for Apache2 MPM

 Param iMSCP::Dialog \%dialog
 Return int 0 to go on next question, 30 to go back to the previous question

=cut

sub askForApache2MPM
{
    my ($self, $dialog) = @_;

    my $value = main::setupGetQuestion( 'HTTPD_MPM', $self->{'config'}->{'HTTPD_MPM'} || ( iMSCP::Getopt->preseed ? 'event' : '' ));
    my %choices = (
        'event', 'Apache2 Event MPM',
        'itk', 'Apache2 ITK MPM',
        'prefork', 'Apache2 Prefork MPM',
        'worker', 'Apache2 Worker MPM'
    );

    if ( isOneOfStringsInList( iMSCP::Getopt->reconfigure, [ 'httpd', 'servers', 'all', 'forced' ] ) || !isStringInList( $value, keys %choices ) ) {
        ( my $rs, $value ) = $dialog->radiolist( <<"EOF", \%choices, ( grep( $value eq $_, keys %choices ) )[0] || 'event' );
\\Z4\\Zb\\ZuApache2 MPM\\Zn

Please choose the Apache2 MPM you want use:
\\Z \\Zn
EOF
        return $rs unless $rs < 30;
    }

    main::setupSetQuestion( 'HTTPD_MPM', $value );
    $self->{'config'}->{'HTTPD_MPM'} = $value;
    0;
}

=item install( )

 See iMSCP::Servers::Abstract::install()

=cut

sub install
{
    my ($self) = @_;

    my $rs = $self->_setVersion();
    $rs ||= $self->_copyDomainDisablePages();
    $rs ||= $self->_setupVlogger();
}

=item uninstall( )

 See iMSCP::Servers::Abstract::uninstall()

=cut

sub uninstall
{
    my ($self) = @_;

    my $rs = $self->_removeVloggerSqlUser();
    return $rs if $rs;

    eval { $self->restart() if iMSCP::Service->getInstance()->hasService( 'apache2' ); };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item setEnginePermissions( )

 See iMSCP::Servers::Abstract::setEnginePermissions()

=cut

sub setEnginePermissions
{
    my ($self) = @_;

    my $rs ||= setRights( "$main::imscpConfig{'TRAFF_ROOT_DIR'}/vlogger",
        {
            user  => $main::imscpConfig{'ROOT_USER'},
            group => $main::imscpConfig{'ROOT_GROUP'},
            mode  => '0750'
        }
    );
    $rs = setRights( $self->{'config'}->{'HTTPD_LOG_DIR'},
        {
            user      => $main::imscpConfig{'ROOT_USER'},
            group     => $main::imscpConfig{'ADM_GROUP'},
            dirmode   => '0755',
            filemode  => '0644',
            recursive => iMSCP::Getopt->fixPermissions
        }
    );
    $rs ||= setRights( "$main::imscpConfig{'USER_WEB_DIR'}/domain_disabled_pages",
        {
            user      => $main::imscpConfig{'ROOT_USER'},
            group     => $self->{'config'}->{'HTTPD_GROUP'},
            dirmode   => '0550',
            filemode  => '0440',
            recursive => iMSCP::Getopt->fixPermissions
        }
    );
}

=item getEventServerName( )

 See iMSCP::Servers::Abstract::getEventServerName()

=cut

sub getEventServerName
{
    my ($self) = @_;

    'Apache2';
}

=item getHumanServerName( )

 See iMSCP::Servers::Abstract::getHumanServerName()

=cut

sub getHumanServerName
{
    my ($self) = @_;

    sprintf( "Apache2 %s (MPM %s)", $self->getVersion(), ucfirst $self->{'config'}->{'HTTPD_MPM'} );
}

=item getVersion( )

 See iMSCP::Servers::Abstract::getVersion()

=cut

sub getVersion
{
    my ($self) = @_;

    $self->{'config'}->{'HTTPD_VERSION'};
}

=item addUser( \%moduleData )

 See iMSCP::Servers::Httpd::addUser()

=cut

sub addUser
{
    my ($self, $moduleData) = @_;

    return 0 if $moduleData->{'STATUS'} eq 'tochangepwd';

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2AddUser', $moduleData );
    $rs ||= iMSCP::SystemUser->new( username => $self->getRunningUser())->addToGroup( $moduleData->{'GROUP'} );
    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2AddUser', $moduleData );
}

=item deleteUser( \%moduleData )

 See iMSCP::Servers::Httpd::deleteUser()

=cut

sub deleteUser
{
    my ($self, $moduleData) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2DeleteUser', $moduleData );
    $rs ||= iMSCP::SystemUser->new( username => $self->getRunningUser())->removeFromGroup( $moduleData->{'GROUP'} );
    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2DeleteUser', $moduleData );
}

=item addDomain( \%moduleData )

 See iMSCP::Servers::Httpd::addDomain()

=cut

sub addDomain
{
    my ($self, $moduleData) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2AddDomain', $moduleData );
    $rs ||= $self->_addCfg( $moduleData );
    $rs ||= $self->_addFiles( $moduleData );
    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2AddDomain', $moduleData );
}

=item restoreDomain( \%moduleData )

 See iMSCP::Servers::Httpd::restoreDmn()

=cut

sub restoreDomain
{
    my ($self, $moduleData) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2RestoreDomain', $moduleData );
    $rs ||= $self->_addFiles( $moduleData );
    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2RestoreDomain', $moduleData );
}

=item disableDomain( \%moduleData )

 See iMSCP::Servers::Httpd::disableDomain()

=cut

sub disableDomain
{
    my ($self, $moduleData) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2DisableDomain', $moduleData );
    $rs ||= $self->_disableDomain( $moduleData );
    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2DisableDomain', $moduleData );
}

=item deleteDomain( \%moduleData )

 See iMSCP::Servers::Httpd::deleteDomain()

=cut

sub deleteDomain
{
    my ($self, $moduleData) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2DeleteDomain', $moduleData );
    $rs ||= $self->_deleteDomain( $moduleData );
    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2DeleteDomain', $moduleData );
}

=item addSubdomain( \%moduleData )

 See iMSCP::Servers::Httpd::addSubdomain()

=cut

sub addSubdomain
{
    my ($self, $moduleData) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2AddSubdomain', $moduleData );
    $rs ||= $self->_addCfg( $moduleData );
    $rs ||= $self->_addFiles( $moduleData );
    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2AddSubdomain', $moduleData );
}

=item restoreSubdomain( \%moduleData )

 See iMSCP::Servers::Httpd::restoreSubdomain()

=cut

sub restoreSubdomain
{
    my ($self, $moduleData) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2RestoreSubdomain', $moduleData );
    $rs ||= $self->_addFiles( $moduleData );
    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2RestoreSubdomain', $moduleData );
}

=item disableSubdomain( \%moduleData )

 See iMSCP::Servers::Httpd::disableSubdomain()

=cut

sub disableSubdomain
{
    my ($self, $moduleData) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2DisableSubdomain', $moduleData );
    $rs ||= $self->_disableDomain( $moduleData );
    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2DisableSubdomain', $moduleData );
}

=item deleteSubdomain( \%moduleData )

 See iMSCP::Servers::Httpd::deleteSubdomain()

=cut

sub deleteSubdomain
{
    my ($self, $moduleData) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2DeleteSubdomain', $moduleData );
    $rs ||= $self->_deleteDomain( $moduleData );
    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2DeleteSubdomain', $moduleData );
}

=item addHtpasswd( \%moduleData )

 See iMSCP::Servers::Httpd::addHtpasswd()

=cut

sub addHtpasswd
{
    my ($self, $moduleData) = @_;

    eval {
        clearImmutable( $moduleData->{'WEB_DIR'} );

        my $file = iMSCP::File->new( filename => "$moduleData->{'WEB_DIR'}/$self->{'config'}->{'HTTPD_HTACCESS_USERS_FILENAME'}" );
        my $fileContentRef;
        if ( -f $file->{'filename'} ) {
            $fileContentRef = $file->getAsRef();
            defined $fileContentRef or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        } else {
            my $stamp = '';
            $fileContentRef = \$stamp;
        }

        $self->{'eventManager'}->trigger( 'beforeApache2AddHtpasswd', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        ${$fileContentRef} =~ s/^$moduleData->{'HTUSER_NAME'}:[^\n]*\n//gim;
        ${$fileContentRef} .= "$moduleData->{'HTUSER_NAME'}:$moduleData->{'HTUSER_PASS'}\n";

        $self->{'eventManager'}->trigger( 'afterApache2AddHtpasswd', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        my $rs = $file->save( 0027 );
        $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $self->{'config'}->{'HTTPD_GROUP'} );
        $rs ||= $file->mode( 0640 );
        $rs == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );

        setImmutable( $moduleData->{'WEB_DIR'} ) if $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes';
    };
    if ( $@ ) {
        error( $@ );

        # Set immutable bit if needed (even on error)
        setImmutable( $moduleData->{'WEB_DIR'} ) if $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes';
        return 1;
    }

    0;
}

=item deleteHtpasswd( \%moduleData )

 See iMSCP::Servers::Httpd::deleteHtpasswd()

=cut

sub deleteHtpasswd
{
    my ($self, $moduleData) = @_;

    eval {
        return unless -f "$moduleData->{'WEB_DIR'}/$self->{'config'}->{'HTTPD_HTACCESS_USERS_FILENAME'}";

        clearImmutable( $moduleData->{'WEB_DIR'} );

        my $file = iMSCP::File->new( filename => "$moduleData->{'WEB_DIR'}/$self->{'config'}->{'HTTPD_HTACCESS_USERS_FILENAME'}" );
        my $fileContentRef;
        if ( -f $file->{'filename'} ) {
            $fileContentRef = $file->getAsRef();
            defined $fileContentRef or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        } else {
            my $stamp = '';
            $fileContentRef = \$stamp;
        }

        $self->{'eventManager'}->trigger( 'beforeApache2DeleteHtpasswd', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        ${$fileContentRef} =~ s/^$moduleData->{'HTUSER_NAME'}:[^\n]*\n//gim;

        $self->{'eventManager'}->trigger( 'afterApache2DeleteHtpasswd', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        my $rs = $file->save();
        $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $self->{'config'}->{'HTTPD_GROUP'} );
        $rs ||= $file->mode( 0640 );
        $rs == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );

        setImmutable( $moduleData->{'WEB_DIR'} ) if $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes';
    };
    if ( $@ ) {
        error( $@ );

        # Set immutable bit if needed (even on error)
        setImmutable( $moduleData->{'WEB_DIR'} ) if $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes';
        return 1;
    }

    0;
}

=item addHtgroup( \%moduleData )

 See iMSCP::Servers::Httpd::addHtgroup()

=cut

sub addHtgroup
{
    my ($self, $moduleData) = @_;

    eval {
        clearImmutable( $moduleData->{'WEB_DIR'} );

        my $file = iMSCP::File->new( filename => "$moduleData->{'WEB_DIR'}/$self->{'config'}->{'HTTPD_HTACCESS_GROUPS_FILENAME'}" );
        my $fileContentRef;
        if ( -f $file->{'filename'} ) {
            $fileContentRef = $file->getAsRef();
            defined $fileContentRef or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        } else {
            my $stamp = '';
            $fileContentRef = \$stamp;
        }

        $self->{'eventManager'}->trigger( 'beforeApache2AddHtgroup', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        ${$fileContentRef} =~ s/^$moduleData->{'HTGROUP_NAME'}:[^\n]*\n//gim;
        ${$fileContentRef} .= "$moduleData->{'HTGROUP_NAME'}:$moduleData->{'HTGROUP_USERS'}\n";

        $self->{'eventManager'}->trigger( 'afterApache2AddHtgroup', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        my $rs = $file->save( 0027 );
        $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $self->{'config'}->{'HTTPD_GROUP'} );
        $rs ||= $file->mode( 0640 );
        $rs == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );

        setImmutable( $moduleData->{'WEB_DIR'} ) if $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes';
    };
    if ( $@ ) {
        error( $@ );

        # Set immutable bit if needed (even on error)
        setImmutable( $moduleData->{'WEB_DIR'} ) if $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes';
        return 1;
    }

    0;
}

=item deleteHtgroup( \%moduleData )

 See iMSCP::Servers::Httpd::deleteHtgroup()

=cut

sub deleteHtgroup
{
    my ($self, $moduleData) = @_;

    eval {
        return 0 unless -f "$moduleData->{'WEB_DIR'}/$self->{'config'}->{'HTTPD_HTACCESS_GROUPS_FILENAME'}";

        clearImmutable( $moduleData->{'WEB_DIR'} );

        my $file = iMSCP::File->new( filename => "$moduleData->{'WEB_DIR'}/$self->{'config'}->{'HTTPD_HTACCESS_GROUPS_FILENAME'}" );
        my $fileContentRef;
        if ( -f $file->{'filename'} ) {
            $fileContentRef = $file->getAsRef();
            defined $fileContentRef or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        } else {
            my $stamp = '';
            $fileContentRef = \$stamp;
        }

        $self->{'eventManager'}->trigger( 'beforeApache2DeleteHtgroup', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        ${$fileContentRef} =~ s/^$moduleData->{'HTGROUP_NAME'}:[^\n]*\n//gim;

        $self->{'eventManager'}->trigger( 'afterApache2DeleteHtgroup', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        my $rs = $file->save();
        $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $self->{'config'}->{'HTTPD_GROUP'} );
        $rs ||= $file->mode( 0640 );
        $rs == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );

        setImmutable( $moduleData->{'WEB_DIR'} ) if $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes';
    };
    if ( $@ ) {
        error( $@ );

        # Set immutable bit if needed (even on error)
        setImmutable( $moduleData->{'WEB_DIR'} ) if $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes';
        return 1;
    }

    0;
}

=item addHtaccess( \%moduleData )

 See iMSCP::Servers::Httpd::addHtaccess()

=cut

sub addHtaccess
{
    my ($self, $moduleData) = @_;

    return 0 unless -d $moduleData->{'AUTH_PATH'};

    my $isImmutable = isImmutable( $moduleData->{'AUTH_PATH'} );

    eval {
        clearImmutable( $moduleData->{'AUTH_PATH'} ) if $isImmutable;

        my $file = iMSCP::File->new( filename => "$moduleData->{'AUTH_PATH'}/.htaccess" );
        my $fileContentRef;
        if ( -f $file->{'filename'} ) {
            $fileContentRef = $file->getAsRef();
            defined $fileContentRef or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        } else {
            my $stamp = '';
            $fileContentRef = \$stamp;
        }

        $self->{'eventManager'}->trigger( 'beforeApache2AddHtaccess', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        my $bTag = "### START i-MSCP PROTECTION ###\n";
        my $eTag = "### END i-MSCP PROTECTION ###\n";
        my $tagContent = <<"EOF";
AuthType $moduleData->{'AUTH_TYPE'}
AuthName "$moduleData->{'AUTH_NAME'}"
AuthBasicProvider file
AuthUserFile $moduleData->{'HOME_PATH'}/$self->{'config'}->{'HTTPD_HTACCESS_USERS_FILENAME'}
EOF

        if ( $moduleData->{'HTUSERS'} eq '' ) {
            $tagContent .= <<"EOF";
AuthGroupFile $moduleData->{'HOME_PATH'}/$self->{'config'}->{'HTTPD_HTACCESS_GROUPS_FILENAME'}
Require group $moduleData->{'HTGROUPS'}
EOF
        } else {
            $tagContent .= <<"EOF";
Require user $moduleData->{'HTUSERS'}
EOF
        }

        replaceBlocByRef( $bTag, $eTag, '', $fileContentRef );
        ${$fileContentRef} = $bTag . $tagContent . $eTag . ${$fileContentRef};

        $self->{'eventManager'}->trigger( 'afterApache2AddHtaccess', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        my $rs = $file->save( 0027 );
        $rs ||= $file->owner( $moduleData->{'USER'}, $moduleData->{'GROUP'} );
        $rs ||= $file->mode( 0640 );
        $rs == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );

        setImmutable( $moduleData->{'AUTH_PATH'} ) if $isImmutable;
    };
    if ( $@ ) {
        error( $@ );

        # Set immutable bit if needed (even on error)
        setImmutable( $moduleData->{'AUTH_PATH'} ) if $isImmutable;
        return 1;
    }

    0;
}

=item deleteHtaccess( \%moduleData )

 See iMSCP::Servers::Httpd::deleteHtaccess()

=cut

sub deleteHtaccess
{
    my ($self, $moduleData) = @_;

    return 0 unless -d $moduleData->{'AUTH_PATH'} && -f "$moduleData->{'AUTH_PATH'}/.htaccess";

    my $isImmutable = isImmutable( $moduleData->{'AUTH_PATH'} );

    eval {
        clearImmutable( $moduleData->{'AUTH_PATH'} ) if $isImmutable;

        my $file = iMSCP::File->new( filename => "$moduleData->{'AUTH_PATH'}/.htaccess" );
        my $fileExist = -f $file->{'filename'};
        my $fileContentRef;

        if ( $fileExist ) {
            $fileContentRef = $file->getAsRef();
            defined $fileContentRef or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        } else {
            my $stamp = '';
            $fileContentRef = \$stamp;
        }

        $self->{'eventManager'}->trigger( 'beforeApache2DeleteHtaccess', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        replaceBlocByRef( "### START i-MSCP PROTECTION ###\n", "### END i-MSCP PROTECTION ###\n", '', $fileContentRef );

        $self->{'eventManager'}->trigger( 'afterApache2DeleteHtaccess', $fileContentRef, $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        if ( ${$fileContentRef} ne '' ) {
            my $rs = $file->save();
            $rs ||= $file->owner( $moduleData->{'USER'}, $moduleData->{'GROUP'} );
            $rs ||= $file->mode( 0640 );
            $rs == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        } elsif ( $fileExist ) {
            $file->delFile() == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        }

        setImmutable( $moduleData->{'AUTH_PATH'} ) if $isImmutable;
    };
    if ( $@ ) {
        error( $@ );

        # Set immutable bit if needed (even on error)
        setImmutable( $moduleData->{'AUTH_PATH'} ) if $isImmutable;
        return 1;
    }

    0;
}

=item buildConfFile( $srcFile, $trgFile, [, \%mdata = { } [, \%sdata [, \%params = { } ] ] ] )

 See iMSCP::Servers::Abstract::buildConfFile()

=cut

sub buildConfFile
{
    my ($self, $srcFile, $trgFile, $mdata, $sdata, $params) = @_;
    $mdata //= {};
    $sdata //= {};
    $params //= {};

    my ($filename, $path) = fileparse( $srcFile );
    my $cfgTpl;

    if ( $params->{'cached'} && exists $self->{'_templates'}->{$srcFile} ) {
        $cfgTpl = $self->{'_templates'}->{$srcFile};
    } else {
        my $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'apache2', $filename, \$cfgTpl, $mdata, $sdata, $self->{'config'}, $params );
        return $rs if $rs;

        unless ( defined $cfgTpl ) {
            $srcFile = File::Spec->canonpath( "$self->{'cfgDir'}/$path/$filename" ) if index( $path, '/' ) != 0;
            $cfgTpl = iMSCP::File->new( filename => $srcFile )->get();
            unless ( defined $cfgTpl ) {
                error( sprintf( "Couldn't read the %s file", $srcFile ));
                return 1;
            }
        }

        $self->{'_templates'}->{$srcFile} = $cfgTpl if $params->{'cached'};
    }

    if ( grep( $_ eq $filename, ( 'domain.tpl', 'domain_disabled.tpl' ) ) ) {
        if ( grep( $_ eq $sdata->{'VHOST_TYPE'}, 'domain', 'domain_disabled' ) ) {
            replaceBlocByRef( "# SECTION ssl BEGIN.\n", "# SECTION ssl END.\n", '', \$cfgTpl );
            replaceBlocByRef( "# SECTION fwd BEGIN.\n", "# SECTION fwd END.\n", '', \$cfgTpl );
        } elsif ( grep( $_ eq $sdata->{'VHOST_TYPE'}, 'domain_fwd', 'domain_ssl_fwd', 'domain_disabled_fwd' ) ) {
            if ( $sdata->{'VHOST_TYPE'} ne 'domain_ssl_fwd' ) {
                replaceBlocByRef( "# SECTION ssl BEGIN.\n", "# SECTION ssl END.\n", '', \$cfgTpl );
            }

            replaceBlocByRef( "# SECTION dmn BEGIN.\n", "# SECTION dmn END.\n", '', \$cfgTpl );
        } elsif ( grep( $_ eq $sdata->{'VHOST_TYPE'}, 'domain_ssl', 'domain_disabled_ssl' ) ) {
            replaceBlocByRef( "# SECTION fwd BEGIN.\n", "# SECTION fwd END.\n", '', \$cfgTpl );
        }
    }

    my $rs = $self->{'eventManager'}->trigger(
        'beforeApache2BuildConfFile', \$cfgTpl, $filename, \$trgFile, $mdata, $sdata, $self->{'config'}, $params
    );
    return $rs if $rs;

    processByRef( $sdata, \$cfgTpl ) if %{$sdata};
    processByRef( $mdata, \$cfgTpl ) if %{$mdata};

    $rs = $self->{'eventManager'}->trigger( 'afterApache2BuildConfFile', \$cfgTpl, $filename, \$trgFile, $mdata, $sdata, $self->{'config'}, $params );
    return $rs if $rs;

    my $fh = iMSCP::File->new( filename => $trgFile );
    $fh->set( $cfgTpl );
    $rs = $fh->save( $params->{'umask'} // undef );
    return $rs if $rs;

    if ( exists $params->{'user'} || exists $params->{'group'} ) {
        $rs = $fh->owner( $params->{'user'} // $main::imscpConfig{'ROOT_USER'}, $params->{'group'} // $main::imscpConfig{'ROOT_GROUP'} );
        return ${$rs} if $rs;
    }

    if ( exists $params->{'mode'} ) {
        $rs = $fh->mode( $params->{'mode'} );
        return $rs if $rs;
    }

    # On configuration file change, schedule server reload
    $self->{'reload'} ||= 1;
    0;
}

=item getTraffic( \%trafficDb )

 See iMSCP::Servers::Httpd::getTraffic()

=cut

sub getTraffic
{
    my (undef, $trafficDb) = @_;

    my $ldate = time2str( '%Y%m%d', time());
    my $dbh = iMSCP::Database->getInstance()->getRawDb();

    debug( sprintf( 'Collecting HTTP traffic data' ));

    eval {
        local $dbh->{'RaiseError'} = 1;
        $dbh->begin_work();
        my $sth = $dbh->prepare( 'SELECT vhost, bytes FROM httpd_vlogger WHERE ldate <= ? FOR UPDATE' );
        $sth->execute( $ldate );

        while ( my $row = $sth->fetchrow_hashref() ) {
            next unless exists $trafficDb->{$row->{'vhost'}};
            $trafficDb->{$row->{'vhost'}} += $row->{'bytes'};
        }

        $dbh->do( 'DELETE FROM httpd_vlogger WHERE ldate <= ?', undef, $ldate );
        $dbh->commit();
    };
    if ( $@ ) {
        $dbh->rollback();
        %{$trafficDb} = ();
        croak( sprintf( "Couldn't collect traffic data: %s", $@ ));
    }

    0;
}

=item getRunningUser( )

 See iMSCP::Servers::Httpd::getRunningUser()

=cut

sub getRunningUser
{
    my ($self) = @_;

    $self->{'config'}->{'HTTPD_USER'};
}

=item getRunningGroup( )

 See iMSCP::Servers::Httpd::getRunningGroup()

=cut

sub getRunningGroup
{
    my ($self) = @_;

    $self->{'config'}->{'HTTPD_GROUP'};
}

=item enableSites( @sites )

 Enable the given sites
 
 Param list @sites List of sites to enable
 Return int 0 on success, other on failure

=cut

sub enableSites
{
    my ($self) = @_;

    croak ( sprintf( 'The %s class must implement the enableSites() method', ref $self ));
}

=item disableSites( @sites )

 Disable the given sites
 
 Param list @sites List of sites to disable
 Return int 0 on success, other on failure

=cut

sub disableSites
{
    my ($self) = @_;

    croak ( sprintf( 'The %s class must implement the disableSites() method', ref $self ));
}

=item enableModules( @modules )

 Enable the given modules
 
 Param list @modules List of modules to enable
 Return int 0 on success, other on failure

=cut

sub enableModules
{
    my ($self) = @_;

    croak ( sprintf( 'The %s class must implement the enableModules() method', ref $self ));
}

=item disableModules( @modules )

 Disable the given modules
 
 Param list @modules List of modules to disable
 Return int 0 on success, other on failure

=cut

sub disableModules
{
    my ($self) = @_;

    croak ( sprintf( 'The %s class must implement the disableModules() method', ref $self ));
}

=item enableConfs( @conffiles )

 Enable the given configuration files
 
 Param list @conffiles List of configuration files to enable
 Return int 0 on success, other on failure

=cut

sub enableConfs
{
    my ($self) = @_;

    croak ( sprintf( 'The %s class must implement the enableConfs() method', ref $self ));
}

=item disableConfs( @conffiles )

 Disable the given configuration files
 
 Param list @conffiles List of configuration files to disable
 Return int 0 on success, other on failure

=cut

sub disableConfs
{
    my ($self) = @_;

    croak ( sprintf( 'The %s class must implement the disableConfs() method', ref $self ));
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 See iMSCP::Servers::Httpd::_init()

=cut

sub _init
{
    my ($self) = @_;

    ref $self ne __PACKAGE__ or croak( sprintf( 'The %s class is an abstract class which cannot be instantiated', __PACKAGE__ ));

    @{$self}{qw/ restart reload _templates cfgDir _web_folder_skeleton /} = ( 0, 0, {}, "$main::imscpConfig{'CONF_DIR'}/apache", undef );
    $self->_loadConfig( 'apache.data' );
    $self->{'eventManager'}->register( 'afterApache2BuildConfFile', $self, -999 );
    $self->SUPER::_init();
}

=item _setVersion( )

 Set Apache2 version

 Return int 0 on success, other on failure

=cut

sub _setVersion
{
    my ($self) = @_;

    croak ( sprintf( 'The %s class must implement the _setVersion() method', ref $self ));
}

=item _deleteDomain( \%moduleData )

 Process deleteDomain tasks

 Param hashref \%moduleData Data as provided by the iMSCP::Modules::Alias|iMSCP::Modules::Domain modules
 Return int 0 on success, other on failure

=cut

sub _deleteDomain
{
    my ($self, $moduleData) = @_;

    my $rs = $self->disableSites( "$moduleData->{'DOMAIN_NAME'}.conf", "$moduleData->{'DOMAIN_NAME'}_ssl.conf" );
    return $rs if $rs;

    for ( "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$moduleData->{'DOMAIN_NAME'}.conf",
        "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$moduleData->{'DOMAIN_NAME'}_ssl.conf",
        "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$moduleData->{'DOMAIN_NAME'}.conf"
    ) {
        next unless -f $_;
        $rs = iMSCP::File->new( filename => $_ )->delFile();
        return $rs if $rs;
    }

    $rs = $self->_umountLogsFolder( $moduleData );
    return $rs if $rs;

    unless ( $moduleData->{'SHARED_MOUNT_POINT'} || !-d $moduleData->{'WEB_DIR'} ) {
        ( my $userWebDir = $main::imscpConfig{'USER_WEB_DIR'} ) =~ s%/+$%%;
        my $parentDir = dirname( $moduleData->{'WEB_DIR'} );

        clearImmutable( $parentDir );
        clearImmutable( $moduleData->{'WEB_DIR'}, 'recursive' );

        eval { iMSCP::Dir->new( dirname => $moduleData->{'WEB_DIR'} )->remove(); };
        if ( $@ ) {
            error( $@ );
            return 1;
        }

        if ( $parentDir ne $userWebDir ) {
            eval {
                my $dir = iMSCP::Dir->new( dirname => $parentDir );
                if ( $dir->isEmpty() ) {
                    clearImmutable( dirname( $parentDir ));
                    $dir->remove();
                }
            };
            if ( $@ ) {
                error( $@ );
                return 1;
            }
        }

        if ( $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes' && $parentDir ne $userWebDir ) {
            do {
                setImmutable( $parentDir ) if -d $parentDir;
            } while ( $parentDir = dirname( $parentDir ) ) ne $userWebDir;
        }
    }

    eval {
        for ( "$moduleData->{'HOME_DIR'}/logs/$moduleData->{'DOMAIN_NAME'}",
            "$self->{'config'}->{'HTTPD_LOG_DIR'}/moduleDatadata->{'DOMAIN_NAME'}"
        ) {
            iMSCP::Dir->new( dirname => $_ )->remove();
        }
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item _mountLogsFolder( \%moduleData )

 Mount logs folder which belong to the given domain into customer's logs folder

 Param hashref \%moduleData Data as provided by the iMSCP::Modules::Alias|iMSCP::Modules::Domain|iMSCP::Modules::Subdomain|iMSCP::Modules::SubAlias modules
 Return int 0 on success, other on failure

=cut

sub _mountLogsFolder
{
    my ($self, $moduleData) = @_;

    my $fsSpec = File::Spec->canonpath( "$self->{'config'}->{'HTTPD_LOG_DIR'}/$moduleData->{'DOMAIN_NAME'}" );
    my $fsFile = File::Spec->canonpath( "$moduleData->{'HOME_DIR'}/logs/$moduleData->{'DOMAIN_NAME'}" );
    my $fields = { fs_spec => $fsSpec, fs_file => $fsFile, fs_vfstype => 'none', fs_mntops => 'bind' };

    unless ( -d $fsFile ) {
        eval {
            iMSCP::Dir->new( dirname => $fsFile )->make( {
                user  => $main::imscpConfig{'ROOT_USER'},
                group => $moduleData->{'GROUP'},
                mode  => 0750
            } );
        };
        if ( $@ ) {
            error( $@ );
            return 1;
        }
    }

    my $rs = addMountEntry( "$fields->{'fs_spec'} $fields->{'fs_file'} $fields->{'fs_vfstype'} $fields->{'fs_mntops'}" );
    $rs ||= mount( $fields ) unless isMountpoint( $fields->{'fs_file'} );
}

=item _umountLogsFolder( \%moduleData )

 Umount logs folder which belong to the given domain from customer's logs folder

 Param hashref \%moduleData Data as provided by the iMSCP::Modules::Alias|iMSCP::Modules::Domain|iMSCP::Modules::Subdomain|iMSCP::Modules::SubAlias modules
 Return int 0 on success, other on failure

=cut

sub _umountLogsFolder
{
    my (undef, $moduleData) = @_;

    my $recursive = 1;
    my $fsFile = "$moduleData->{'HOME_DIR'}/logs";

    # We operate recursively only if domain type is 'dmn' (full account)
    if ( $moduleData->{'DOMAIN_TYPE'} ne 'dmn' ) {
        $recursive = 0;
        $fsFile .= "/$moduleData->{'DOMAIN_NAME'}";
    }

    $fsFile = File::Spec->canonpath( $fsFile );
    my $rs ||= removeMountEntry( qr%.*?[ \t]+\Q$fsFile\E(?:/|[ \t]+)[^\n]+% );
    $rs ||= umount( $fsFile, $recursive );
}

=item _disableDomain( \%moduleData )

 Disable a domain

 Param hashref \%moduleData Data as provided by the iMSCP::Modules::Alias|iMSCP::Modules::Domain modules
 Return int 0 on success, other on failure

=cut

sub _disableDomain
{
    my ($self, $moduleData) = @_;

    eval {
        iMSCP::Dir->new( dirname => "$self->{'config'}->{'HTTPD_LOG_DIR'}/$moduleData->{'DOMAIN_NAME'}" )->make( {
            user  => $main::imscpConfig{'ROOT_USER'},
            group => $main::imscpConfig{'ADM_GROUP'},
            mode  => 0755
        } );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    my $net = iMSCP::Net->getInstance();
    my @domainIPs = ( $moduleData->{'DOMAIN_IP'}, ( $main::imscpConfig{'CLIENT_DOMAIN_ALT_URLS'} eq 'yes' ? $moduleData->{'BASE_SERVER_IP'} : () ) );

    my $rs = $self->{'eventManager'}->trigger( 'onApache2AddVhostIps', $moduleData, \@domainIPs );
    return $rs if $rs;

    # If INADDR_ANY is found, map it to the wildcard sign and discard any other
    # IP, else, remove any duplicate IP address from the list
    @domainIPs = sort grep($_ eq '0.0.0.0', @domainIPs) ? ( '*' ) : unique( map { $net->normalizeAddr( $_ ) } @domainIPs );

    my $serverData = {
        DOMAIN_IPS      => join( ' ', map { ( ( $_ eq '*' || $net->getAddrVersion( $_ ) eq 'ipv4' ) ? $_ : "[$_]" ) . ':80' } @domainIPs ),
        HTTP_URI_SCHEME => 'http://',
        HTTPD_LOG_DIR   => $self->{'config'}->{'HTTPD_LOG_DIR'},
        USER_WEB_DIR    => $main::imscpConfig{'USER_WEB_DIR'},
        SERVER_ALIASES  => "www.$moduleData->{'DOMAIN_NAME'}" . ( $main::imscpConfig{'CLIENT_DOMAIN_ALT_URLS'} eq 'yes'
            ? " $moduleData->{'ALIAS'}.$main::imscpConfig{'BASE_SERVER_VHOST'}" : ''
        )
    };

    # Create http vhost

    if ( $moduleData->{'HSTS_SUPPORT'} ) {
        @{$serverData}{qw/ FORWARD FORWARD_TYPE VHOST_TYPE /} = ( "https://$moduleData->{'DOMAIN_NAME'}/", 301, 'domain_disabled_fwd' );
    } else {
        $serverData->{'VHOST_TYPE'} = 'domain_disabled';
    }

    $rs = $self->buildConfFile( 'parts/domain_disabled.tpl', "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$moduleData->{'DOMAIN_NAME'}.conf",
        $moduleData, $serverData, { cached => 1 }
    );

    $rs ||= $self->enableSites( "$moduleData->{'DOMAIN_NAME'}.conf" );
    return $rs if $rs;

    # Create https vhost (or delete it if SSL is disabled)

    if ( $moduleData->{'SSL_SUPPORT'} ) {
        @{$serverData}{qw/ CERTIFICATE DOMAIN_IPS HTTP_URI_SCHEME VHOST_TYPE /} = (
            "$main::imscpConfig{'GUI_ROOT_DIR'}/data/certs/$moduleData->{'DOMAIN_NAME'}.pem",
            join( ' ', map { ( ( $_ eq '*' || $net->getAddrVersion( $_ ) eq 'ipv4' ) ? $_ : "[$_]" ) . ':443' } @domainIPs ),
            'https://',
            'domain_disabled_ssl'
        );

        $rs = $self->buildConfFile( 'parts/domain_disabled.tpl',
            "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$moduleData->{'DOMAIN_NAME'}_ssl.conf", $moduleData, $serverData, { cached => 1 }
        );
        $rs ||= $self->enableSites( "$moduleData->{'DOMAIN_NAME'}_ssl.conf" );
        return $rs if $rs;
    } else {
        # Try to disable the site in any case to cover possible dangling symlink
        $rs = $self->disableSites( "$moduleData->{'DOMAIN_NAME'}_ssl.conf" );
        return $rs if $rs;

        if ( -f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$moduleData->{'DOMAIN_NAME'}_ssl.conf" ) {
            $rs ||= iMSCP::File->new(
                filename => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$moduleData->{'DOMAIN_NAME'}_ssl.conf"
            )->delFile();
            return $rs if $rs;
        }
    }

    # Make sure that custom httpd conffile exists (cover case where file has been removed for any reasons)
    unless ( -f "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$moduleData->{'DOMAIN_NAME'}.conf" ) {
        $serverData->{'SKIP_TEMPLATE_CLEANER'} = 1;
        $rs = $self->buildConfFile( 'parts/custom.conf.tpl', "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$moduleData->{'DOMAIN_NAME'}.conf",
            $moduleData, $serverData, { cached => 1 }
        );
        return $rs if $rs;
    }

    # Transitional - Remove deprecated `domain_disable_page' directory if any
    if ( $moduleData->{'DOMAIN_TYPE'} eq 'dmn' && -d $moduleData->{'WEB_DIR'} ) {
        clearImmutable( $moduleData->{'WEB_DIR'} );
        eval { iMSCP::Dir->new( dirname => "$moduleData->{'WEB_DIR'}/domain_disable_page" )->remove(); };
        if ( $@ ) {
            error( $@ );
            $rs = 1;
        }

        # Set immutable bit if needed (even on error)
        setImmutable( $moduleData->{'WEB_DIR'} ) if $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes';
        return $rs if $rs;
    }

    0;
}

=item _addCfg( \%data )

 Add configuration files for the given domain

 Param hashref \%data Data as provided by the iMSCP::Modules::Alias|iMSCP::Modules::Domain|iMSCP::Modules::Subdomain|iMSCP::Modules::SubAlias modules
 Return int 0 on success, other on failure

=cut

sub _addCfg
{
    my ($self, $moduleData) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeApache2AddCfg', $moduleData );
    return $rs if $rs;

    my $net = iMSCP::Net->getInstance();
    my @domainIPs = ( $moduleData->{'DOMAIN_IP'}, ( $main::imscpConfig{'CLIENT_DOMAIN_ALT_URLS'} eq 'yes' ? $moduleData->{'BASE_SERVER_IP'} : () ) );

    $rs = $self->{'eventManager'}->trigger( 'onApache2AddVhostIps', $moduleData, \@domainIPs );
    return $rs if $rs;

    # If INADDR_ANY is found, map it to the wildcard sign and discard any other
    # IP, else, remove any duplicate IP address from the list
    @domainIPs = sort grep($_ eq '0.0.0.0', @domainIPs) ? ( '*' ) : unique( map { $net->normalizeAddr( $_ ) } @domainIPs );

    my $serverData = {
        DOMAIN_IPS             => join( ' ', map { ( ( $_ eq '*' || $net->getAddrVersion( $_ ) eq 'ipv4' ) ? $_ : "[$_]" ) . ':80' } @domainIPs ),
        HTTPD_CUSTOM_SITES_DIR => $self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'},
        HTTPD_LOG_DIR          => $self->{'config'}->{'HTTPD_LOG_DIR'},
        SERVER_ALIASES         => "www.$moduleData->{'DOMAIN_NAME'}" . (
                $main::imscpConfig{'CLIENT_DOMAIN_ALT_URLS'} eq 'yes' ? " $moduleData->{'ALIAS'}.$main::imscpConfig{'BASE_SERVER_VHOST'}" : ''
        )
    };

    # Create http vhost

    if ( $moduleData->{'HSTS_SUPPORT'} ) {
        @{$serverData}{qw/ FORWARD FORWARD_TYPE VHOST_TYPE /} = ( "https://$moduleData->{'DOMAIN_NAME'}/", 301, 'domain_fwd' );
    } elsif ( $moduleData->{'FORWARD'} ne 'no' ) {
        $serverData->{'VHOST_TYPE'} = 'domain_fwd';
        @{$serverData}{qw/ X_FORWARDED_PROTOCOL X_FORWARDED_PORT /} = ( 'http', 80 ) if $moduleData->{'FORWARD_TYPE'} eq 'proxy';
    } else {
        $serverData->{'VHOST_TYPE'} = 'domain';
    }

    $rs = $self->buildConfFile( 'parts/domain.tpl', "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$moduleData->{'DOMAIN_NAME'}.conf", $moduleData,
        $serverData, { cached => 1 }
    );

    $rs ||= $self->enableSites( "$moduleData->{'DOMAIN_NAME'}.conf" );
    return $rs if $rs;

    # Create https vhost (or delete it if SSL is disabled)

    if ( $moduleData->{'SSL_SUPPORT'} ) {
        @{$serverData}{qw/ CERTIFICATE DOMAIN_IPS /} = (
            "$main::imscpConfig{'GUI_ROOT_DIR'}/data/certs/$moduleData->{'DOMAIN_NAME'}.pem",
            join( ' ', map { ( ( $_ eq '*' || $net->getAddrVersion( $_ ) eq 'ipv4' ) ? $_ : "[$_]" ) . ':443' } @domainIPs )
        );

        if ( $moduleData->{'FORWARD'} ne 'no' ) {
            @{$serverData}{qw/ FORWARD FORWARD_TYPE VHOST_TYPE /} = ( $moduleData->{'FORWARD'}, $moduleData->{'FORWARD_TYPE'}, 'domain_ssl_fwd' );
            @{$serverData}{qw/ X_FORWARDED_PROTOCOL X_FORWARDED_PORT /} = ( 'https', 443 ) if $moduleData->{'FORWARD_TYPE'} eq 'proxy';
        } else {
            $serverData->{'VHOST_TYPE'} = 'domain_ssl';
        }

        $rs = $self->buildConfFile( 'parts/domain.tpl', "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$moduleData->{'DOMAIN_NAME'}_ssl.conf",
            $moduleData, $serverData, { cached => 1 }
        );
        $rs ||= $self->enableSites( "$moduleData->{'DOMAIN_NAME'}_ssl.conf" );
        return $rs if $rs;
    } else {
        # Try to disable the site in any case to cover possible dangling symlink
        $rs = $self->disableSites( "$moduleData->{'DOMAIN_NAME'}_ssl.conf" );
        return $rs if $rs;

        if ( -f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$moduleData->{'DOMAIN_NAME'}_ssl.conf" ) {
            $rs ||= iMSCP::File->new(
                filename => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$moduleData->{'DOMAIN_NAME'}_ssl.conf"
            )->delFile();
            return $rs if $rs;
        }
    }

    unless ( -f "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$moduleData->{'DOMAIN_NAME'}.conf" ) {
        $serverData->{'SKIP_TEMPLATE_CLEANER'} = 1;
        $rs = $self->buildConfFile( 'parts/custom.conf.tpl', "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$moduleData->{'DOMAIN_NAME'}.conf",
            $moduleData, $serverData, { cached => 1 }
        );
    }

    $rs ||= $self->{'eventManager'}->trigger( 'afterApache2AddCfg', $moduleData );
}


=item _getWebfolderSkeleton( \%moduleData )

 Get Web folder skeleton

 Param hashref \%moduleData Data as provided by the iMSCP::Modules::Alias|iMSCP::Modules::Domain|iMSCP::Modules::Subdomain|iMSCP::Modules::SubAlias modules
 Return string Path to Web folder skeleton on success, croak on failure

=cut

sub _getWebfolderSkeleton
{
    my (undef, $moduleData) = @_;

    my $webFolderSkeleton = $moduleData->{'DOMAIN_TYPE'} eq 'dmn' ? 'domain' : ( $moduleData->{'DOMAIN_TYPE'} eq 'als' ? 'alias' : 'subdomain' );

    unless ( -d "$TMPFS/$webFolderSkeleton" ) {
        iMSCP::Dir->new(
            dirname => "$main::imscpConfig{'CONF_DIR'}/skel/$webFolderSkeleton" )->rcopy( "$TMPFS/$webFolderSkeleton", { preserve => 'no' }
        );

        if ( $moduleData->{'DOMAIN_TYPE'} eq 'dmn' ) {
            for ( qw/ errors logs / ) {
                next if -d "$TMPFS/$webFolderSkeleton/$_";
                iMSCP::Dir->new( dirname => "$TMPFS/$webFolderSkeleton/$_" )->make();
            }
        }

        iMSCP::Dir->new( dirname => "$TMPFS/$webFolderSkeleton/htdocs" )->make() unless -d "$TMPFS/$webFolderSkeleton/htdocs";
    }

    "$TMPFS/$webFolderSkeleton";
}

=item _addFiles( \%moduleData )

 Add default directories and files for the given domain

 Param hashref \%moduleData Data as provided by the iMSCP::Modules::Alias|iMSCP::Modules::Domain|iMSCP::Modules::Subdomain|iMSCP::Modules::SubAlias modules
 Return int 0 on sucess, other on failure

=cut

sub _addFiles
{
    my ($self, $moduleData) = @_;

    eval {
        $self->{'eventManager'}->trigger( 'beforeApache2AddFiles', $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        iMSCP::Dir->new( dirname => "$self->{'config'}->{'HTTPD_LOG_DIR'}/$moduleData->{'DOMAIN_NAME'}" )->make( {
            user  => $main::imscpConfig{'ROOT_USER'},
            group => $main::imscpConfig{'ADM_GROUP'},
            mode  => 0755
        } );

        # Whether or not permissions must be fixed recursively
        my $fixPermissions = iMSCP::Getopt->fixPermissions || grep( $moduleData->{'ACTION'} eq $_, 'restoreDomain', 'restoreSubdomain' );

        #
        ## Prepare Web folder
        #

        my $webFolderSkeleton = $self->_getWebfolderSkeleton( $moduleData );
        my $workingWebFolder = File::Temp->newdir( DIR => $TMPFS );

        iMSCP::Dir->new( dirname => $webFolderSkeleton )->rcopy( $workingWebFolder );

        if ( -d "$moduleData->{'WEB_DIR'}/htdocs" ) {
            iMSCP::Dir->new( dirname => "$workingWebFolder/htdocs" )->remove();
        } else {
            # Always fix permissions recursively for newly created Web folders
            $fixPermissions = 1;
        }

        if ( $moduleData->{'DOMAIN_TYPE'} eq 'dmn' && -d "$moduleData->{'WEB_DIR'}/errors" ) {
            iMSCP::Dir->new( dirname => "$workingWebFolder/errors" )->remove();
        }

        # Make sure that parent Web folder exists
        my $parentDir = dirname( $moduleData->{'WEB_DIR'} );
        unless ( -d $parentDir ) {
            clearImmutable( dirname( $parentDir ));
            iMSCP::Dir->new( dirname => $parentDir )->make( {
                user  => $moduleData->{'USER'},
                group => $moduleData->{'GROUP'},
                mode  => 0750
            } );
        } else {
            clearImmutable( $parentDir );
        }

        clearImmutable( $moduleData->{'WEB_DIR'} ) if -d $moduleData->{'WEB_DIR'};

        if ( $moduleData->{'DOMAIN_TYPE'} eq 'dmn' ) {
            $self->_umountLogsFolder( $moduleData ) == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );

            if ( $self->{'config'}->{'HTTPD_MOUNT_CUSTOMER_LOGS'} ne 'yes' ) {
                iMSCP::Dir->new( dirname => "$moduleData->{'WEB_DIR'}/logs" )->remove();
                iMSCP::Dir->new( dirname => "$workingWebFolder/logs" )->remove();
            }
        }

        #
        ## Create Web folder
        #

        iMSCP::Dir->new( dirname => $workingWebFolder )->rcopy( $moduleData->{'WEB_DIR'}, { preserve => 'no' } );

        # Set ownership and permissions

        # Set ownership and permissions for the Web folder root
        # Web folder root vuxxx:vuxxx 0750 (no recursive)
        setRights( $moduleData->{'WEB_DIR'},
            {
                user  => $moduleData->{'USER'},
                group => $moduleData->{'GROUP'},
                mode  => '0750'
            }
        ) == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );

        # Get list of possible files inside Web folder root
        my @files = iMSCP::Dir->new( dirname => $webFolderSkeleton )->getAll();

        # Set ownership for Web folder
        for ( @files ) {
            next unless -e "$moduleData->{'WEB_DIR'}/$_";
            setRights( "$moduleData->{'WEB_DIR'}/$_",
                {
                    user      => $moduleData->{'USER'},
                    group     => $moduleData->{'GROUP'},
                    recursive => $fixPermissions
                }
            ) == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        }

        if ( $moduleData->{'DOMAIN_TYPE'} eq 'dmn' ) {
            # Set ownership and permissions for .htgroup and .htpasswd files
            for ( qw/ .htgroup .htpasswd / ) {
                next unless -f "$moduleData->{'WEB_DIR'}/$_";
                setRights( "$moduleData->{'WEB_DIR'}/$_",
                    {
                        user  => $main::imscpConfig{'ROOT_USER'},
                        group => $self->getRunningGroup(),
                        mode  => '0640'
                    }
                ) == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
            }

            # Set ownership for logs directory
            if ( $self->{'config'}->{'HTTPD_MOUNT_CUSTOMER_LOGS'} eq 'yes' ) {
                setRights( "$moduleData->{'WEB_DIR'}/logs",
                    {
                        user      => $main::imscpConfig{'ROOT_USER'},
                        group     => $moduleData->{'GROUP'},
                        recursive => $fixPermissions
                    }
                ) == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
            }
        }

        # Set permissions for Web folder
        for my $file ( @files ) {
            next unless -e "$moduleData->{'WEB_DIR'}/$file";
            setRights( "$moduleData->{'WEB_DIR'}/$file",
                {
                    dirmode   => '0750',
                    filemode  => '0640',
                    recursive => $file =~ /^(?:00_private|cgi-bin|htdocs)$/ ? 0 : $fixPermissions
                }
            ) == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        }

        if ( $self->{'config'}->{'HTTPD_MOUNT_CUSTOMER_LOGS'} eq 'yes' ) {
            $self->_mountLogsFolder( $moduleData ) == 0 or croak( getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' );
        }

        $self->{'eventManager'}->trigger( 'afterApache2AddFiles', $moduleData ) == 0 or croak(
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        );

        # Set immutable bit if needed
        if ( $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes' ) {
            my $dir = $moduleData->{'WEB_DIR'};
            my $userWebDir = File::Spec->canonpath( $main::imscpConfig{'USER_WEB_DIR'} );
            do {
                setImmutable( $dir );
            } while ( $dir = dirname( $dir ) ) ne $userWebDir;
        }
    };
    if ( $@ ) {
        error( $@ );

        # Set immutable bit if needed (even on error)
        if ( $moduleData->{'WEB_FOLDER_PROTECTION'} eq 'yes' ) {
            my $dir = $moduleData->{'WEB_DIR'};
            my $userWebDir = File::Spec->canonpath( $main::imscpConfig{'USER_WEB_DIR'} );
            do {
                setImmutable( $dir );
            } while ( $dir = dirname( $dir ) ) ne $userWebDir;
        }

        return 1;
    }

    0;
}

=item _copyDomainDisablePages( )

 Copy pages for disabled domains

 Return int 0 on success, other on failure

=cut

sub _copyDomainDisablePages
{
    eval {
        iMSCP::Dir->new( dirname => "$main::imscpConfig{'CONF_DIR'}/skel/domain_disabled_pages" )->rcopy(
            "$main::imscpConfig{'USER_WEB_DIR'}/domain_disabled_pages", { preserve => 'no' }
        );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item _setupVlogger( )

 Setup vlogger

 Return int 0 on success, other on failure

=cut

sub _setupVlogger
{
    my ($self) = @_;

    {
        my $dbSchemaFile = File::Temp->new();
        print $dbSchemaFile <<"EOF";
USE `{DATABASE_NAME}`;

CREATE TABLE IF NOT EXISTS httpd_vlogger (
  vhost varchar(255) NOT NULL,
  ldate int(8) UNSIGNED NOT NULL,
  bytes int(32) UNSIGNED NOT NULL DEFAULT '0',
  PRIMARY KEY(vhost,ldate)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;
EOF
        $dbSchemaFile->close();
        my $rs = $self->buildConfFile( $dbSchemaFile, $dbSchemaFile, undef, { DATABASE_NAME => main::setupGetQuestion( 'DATABASE_NAME' ) },
            { srcname => 'vlogger.sql' }
        );
        return $rs if $rs;

        my $defaultExtrafile = File::Temp->new();
        print $defaultExtrafile <<"EOF";
[mysql_upgrade]
host = {HOST}
port = {PORT}
user = "{USER}"
password = "{PASSWORD}"
EOF
        $defaultExtrafile->close();
        $rs = $self->buildConfFile( $defaultExtrafile, $defaultExtrafile, undef,
            {
                HOST     => main::setupGetQuestion( 'DATABASE_HOST' ),
                PORT     => main::setupGetQuestion( 'DATABASE_PORT' ),
                USER     => main::setupGetQuestion( 'DATABASE_USER' ) =~ s/"/\\"/gr,
                PASSWORD => decryptRijndaelCBC( $main::imscpKEY, $main::imscpIV, main::setupGetQuestion( 'DATABASE_PASSWORD' )) =~ s/"/\\"/gr
            },
            { srcname => 'default-extra-file' }
        );
        return $rs if $rs;

        $rs = execute( "cat $dbSchemaFile | /usr/bin/mysql --defaults-extra-file=$defaultExtrafile", \ my $stdout, \ my $stderr );
        debug( $stdout ) if $stdout;
        error( $stderr || 'Unknown error' ) if $rs;
        return $rs if $rs;
    }

    my $dbHost = main::setupGetQuestion( 'DATABASE_HOST' );
    $dbHost = '127.0.0.1' if $dbHost eq 'localhost';
    my $dbPort = main::setupGetQuestion( 'DATABASE_PORT' );
    my $dbName = main::setupGetQuestion( 'DATABASE_NAME' );
    my $dbUser = 'vlogger_user';
    my $dbUserHost = main::setupGetQuestion( 'DATABASE_USER_HOST' );
    $dbUserHost = '127.0.0.1' if $dbUserHost eq 'localhost';
    my $oldUserHost = $main::imscpOldConfig{'DATABASE_USER_HOST'};
    my $dbPass = randomStr( 16, ALNUM );

    eval {
        my $sqlServer = iMSCP::Servers::Sqld->factory();

        for ( $dbUserHost, $oldUserHost, 'localhost' ) {
            next unless $_;
            $sqlServer->dropUser( $dbUser, $_ );
        }

        $sqlServer->createUser( $dbUser, $dbUserHost, $dbPass );

        my $dbh = iMSCP::Database->getInstance()->getRawDb();
        local $dbh->{'RaiseError'} = 1;

        # No need to escape wildcard characters. See https://bugs.mysql.com/bug.php?id=18660
        my $qDbName = $dbh->quote_identifier( $dbName );
        $dbh->do( "GRANT SELECT, INSERT, UPDATE ON $qDbName.httpd_vlogger TO ?\@?", undef, $dbUser, $dbUserHost );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    my $conffile = File::Temp->new();
    print $conffile <<'EOF';
# vlogger configuration file - auto-generated by i-MSCP
#     DO NOT EDIT THIS FILE BY HAND -- YOUR CHANGES WILL BE OVERWRITTEN
dsn    dbi:mysql:database={DATABASE_NAME};host={DATABASE_HOST};port={DATABASE_PORT}
user   {DATABASE_USER}
pass   {DATABASE_PASSWORD}
dump   30
EOF
    $conffile->close();
    $self->buildConfFile( $conffile, "$self->{'config'}->{'HTTPD_CONF_DIR'}/vlogger.conf", undef,
        {
            DATABASE_NAME         => $dbName,
            DATABASE_HOST         => $dbHost,
            DATABASE_PORT         => $dbPort,
            DATABASE_USER         => $dbUser,
            DATABASE_PASSWORD     => $dbPass,
            SKIP_TEMPLATE_CLEANER => 1
        },
        {
            umask   => 0027,
            mode    => 0640,
            srcname => 'vlogger.conf'
        }
    );
}

=item _removeVloggerSqlUser( )

 Remove vlogger SQL user

 Return int 0

=cut

sub _removeVloggerSqlUser
{
    if ( $main::imscpConfig{'DATABASE_USER_HOST'} eq 'localhost' ) {
        return iMSCP::Servers::Sqld->factory()->dropUser( 'vlogger_user', '127.0.0.1' );
    }

    iMSCP::Servers::Sqld->factory()->dropUser( 'vlogger_user', $main::imscpConfig{'DATABASE_USER_HOST'} );
}

=back

=head1 EVENT LISTENERS

=over 4

=item afterApache2BuildConfFile( $apache2Server, \$cfgTpl, $filename, \$trgFile, \%moduleData, \%apache2ServerData, \%apache2ServerConfig, \%parameters )

 Event listener that cleanup production files

 Param scalar $apache2Server iMSCP::Servers::Httpd::Apache2::Prefork instance
 Param scalar \$scalar Reference to Apache2 conffile
 Param string $filename Apache2 template name
 Param scalar \$trgFile Target file path
 Param hashref \%moduleData Data as provided by the iMSCP::Modules::Alias|iMSCP::Modules::Domain|iMSCP::Modules::Subdomain|iMSCP::Modules::SubAlias modules
 Param hashref \%apache2ServerData Apache2 server data
 Param hashref \%apache2ServerConfig Apache2 server data
 Param hashref \%parameters OPTIONAL Parameters:
  - user  : File owner (default: root)
  - group : File group (default: root
  - mode  : File mode (default: 0644)
  - cached : Whether or not loaded file must be cached in memory
 Return int 0 on success, other on failure

=cut

sub afterApache2BuildConfFile
{
    my ($self, $cfgTpl, $filename, undef, $moduleData, $apache2ServerData) = @_;

    return $apache2ServerData->{'SKIP_TEMPLATE_CLEANER'} = 0 if $apache2ServerData->{'SKIP_TEMPLATE_CLEANER'};

    if ( $filename eq 'domain.tpl' ) {
        if ( index( $apache2ServerData->{'VHOST_TYPE'}, 'fwd' ) == -1 ) {
            if ( $self->{'config'}->{'HTTPD_MPM'} eq 'itk' ) {
                replaceBlocByRef( "# SECTION suexec BEGIN.\n", "# SECTION suexec END.\n", '', $cfgTpl );
            } else {
                replaceBlocByRef( "# SECTION itk BEGIN.\n", "# SECTION itk END.\n", '', $cfgTpl );
            }

            if ( $moduleData->{'CGI_SUPPORT'} ne 'yes' ) {
                replaceBlocByRef( "# SECTION cgi BEGIN.\n", "# SECTION cgi END.\n", '', $cfgTpl );
            }
        } elsif ( $moduleData->{'FORWARD'} ne 'no' ) {
            if ( $moduleData->{'FORWARD_TYPE'} eq 'proxy'
                && ( !$moduleData->{'HSTS_SUPPORT'} || index( $apache2ServerData->{'VHOST_TYPE'}, 'ssl' ) != -1 )
            ) {
                replaceBlocByRef( "# SECTION std_fwd BEGIN.\n", "# SECTION std_fwd END.\n", '', $cfgTpl );

                if ( index( $moduleData->{'FORWARD'}, 'https' ) != 0 ) {
                    replaceBlocByRef( "# SECTION ssl_proxy BEGIN.\n", "# SECTION ssl_proxy END.\n", '', $cfgTpl );
                }
            } else {
                replaceBlocByRef( "# SECTION proxy_fwd BEGIN.\n", "# SECTION proxy_fwd END.\n", '', $cfgTpl );
            }
        } else {
            replaceBlocByRef( "# SECTION proxy_fwd BEGIN.\n", "# SECTION proxy_fwd END.\n", '', $cfgTpl );
        }
    }

    ${$cfgTpl} =~ s/^\s*(?:[#;].*)?\n//gm;
    0;
}

=back

=head1 CLEANUP TASKS

=over 4

=item DESTROY

 Umount and remove tmpfs

=cut

sub DESTROY
{
    my ($self) = @_;

    my $tmpfs = "$main::imscpConfig{'IMSCP_HOMEDIR'}/tmp/apache2_tmpfs";
    umount( $tmpfs ) if isMountpoint( $tmpfs );
    iMSCP::Dir->new( dirname => $tmpfs )->remove();

    $self->SUPER::DESTROY();
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
