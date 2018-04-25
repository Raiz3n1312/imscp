<?php
/**
 * i-MSCP - internet Multi Server Control Panel
 * Copyright (C) 2010-2018 by Laurent Declercq <l.declercq@nuxwin.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

namespace iMSCP;

use iMSCP\Functions\Daemon;
use iMSCP\Functions\Login;
use iMSCP\Functions\View;

Login::checkLogin('user');
Application::getInstance()->getEventManager()->trigger(Events::onClientScriptStart);
customerHasFeature('mail') && isset($_GET['id']) or View::showBadRequestErrorPage();
$catchallId = intval($_GET['id']);
$stmt = execQuery('SELECT COUNT(mail_id) FROM mail_users JOIN domain USING(domain_id) WHERE mail_id = ? AND domain_admin_id = ?', [
    $catchallId, Application::getInstance()->getSession()['user_id']
]);
$stmt->fetchColumn() or View::showBadRequestErrorPage();
Application::getInstance()->getEventManager()->trigger(Events::onBeforeDeleteMailCatchall, NULL, ['mailCatchallId' => $catchallId]);
execQuery("UPDATE mail_users SET status = 'todelete' WHERE mail_id = ?", [$catchallId]);
Application::getInstance()->getEventManager()->trigger(Events::onAfterDeleteMailCatchall, NULL, ['mailCatchallId' => $catchallId]);
Daemon::sendRequest();
writeLog(sprintf('A catch-all account has been deleted by %s', Application::getInstance()->getSession()['user_logged']), E_USER_NOTICE);
setPageMessage(tr('Catch-all account successfully scheduled for deletion.'), 'success');
redirectTo('mail_catchall.php');
