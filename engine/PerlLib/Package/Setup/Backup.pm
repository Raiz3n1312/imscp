=head1 NAME

 Package::Setup::Backup - i-MSCP backup

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

package Package::Setup::Backup;

use strict;
use warnings;
use iMSCP::Boolean;
use iMSCP::Dialog::InputValidation qw/ isOneOfStringsInList isStringInList /;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP backup.

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

    $eventManager->register( 'beforeSetupDialog', sub {
        push @{ $_[0] },
            sub { $self->askForCpBackup( @_ ) },
            sub { $self->askForClientsBackup( @_ ) };
        0;
    } );
}

=item askForCpBackup( $dialog )

 Ask for control panel backup

 Param iMSCP::Dialog $dialog
 Return int 0 (NEXT), 30 (BACK), 50 (ESC)

=cut

sub askForCpBackup
{
    my ( undef, $dialog ) = @_;

    my $value = ::setupGetQuestion( 'BACKUP_IMSCP' );

    if ( isOneOfStringsInList( iMSCP::Getopt->reconfigure, [ 'cp_backup', 'backup', 'all' ] ) || !isStringInList( $value, 'yes', 'no' ) ) {
        my $rs = $dialog->yesno( <<'EOF', $value eq 'no', TRUE );

Do you want enable daily backup for the control panel (database and configuration files)?
EOF
        return $rs unless $rs < 30;
        $value = $rs ? 'no' : 'yes'
    }

    ::setupSetQuestion( 'BACKUP_IMSCP', $value );
    0;
}

=item askForClientsBackup( $dialog )

 Ask for clients backup

 Param iMSCP::Dialog $dialog
 Return int 0 (NEXT), 30 (BACK), 50 (ESC)

=cut

sub askForClientsBackup
{
    my ( undef, $dialog ) = @_;

    my $value = ::setupGetQuestion( 'BACKUP_DOMAINS' );

    if ( isOneOfStringsInList( iMSCP::Getopt->reconfigure, [ 'client_backup', 'backup', 'all' ] ) || !isStringInList( $value, 'yes', 'no' ) ) {
        my $rs = $dialog->yesno( <<'EOF', $value eq 'no', TRUE );

Do you want to activate the backup feature for the clients?
EOF
        return $rs unless $rs < 30;
        $value = $rs ? 'no' : 'yes'
    }

    ::setupSetQuestion( 'BACKUP_DOMAINS', $value );
    0;
}

=item getPriority( )

 Get package priority

 Return int package priority

=cut

sub getPriority
{
    0;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
