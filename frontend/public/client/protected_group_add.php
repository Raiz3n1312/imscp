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

/**
 * Adds Htaccess group
 *
 * @return void
 */
function client_addHtaccessGroup()
{
    if (empty($_POST)) {
        return;
    }

    isset($_POST['groupname']) or View::showBadRequestErrorPage();

    $htgroupName = cleanInput($_POST['groupname']);

    if (!validateUsername($htgroupName)) {
        setPageMessage(tr('Invalid group name!'), 'error');
        return;
    }

    $domainId = getCustomerMainDomainId(Application::getInstance()->getSession()['user_id']);

    $stmt = execQuery('SELECT id FROM htaccess_groups WHERE ugroup = ? AND dmn_id = ?', [$htgroupName, $domainId]);
    if ($stmt->rowCount()) {
        setPageMessage(tr('This htaccess group already exists.'), 'error');
    }

    execQuery("INSERT INTO htaccess_groups (dmn_id, ugroup, status) VALUES (?, ?, 'toadd')", [$domainId, $htgroupName]);
    Daemon::sendRequest();
    setPageMessage(tr('Htaccess group successfully scheduled for addition.'), 'success');
    writeLog(sprintf('%s added htaccess group: %s', Application::getInstance()->getSession()['user_logged'], $htgroupName), E_USER_NOTICE);
    redirectTo('protected_user_manage.php');
}

Login::checkLogin('user');
Application::getInstance()->getEventManager()->trigger(Events::onClientScriptStart);
customerHasFeature('protected_areas') or View::showBadRequestErrorPage();
client_addHtaccessGroup();

$tpl = new TemplateEngine();
$tpl->define([
    'layout'       => 'shared/layouts/ui.tpl',
    'page'         => 'client/puser_gadd.tpl',
    'page_message' => 'layout',
]);
$tpl->assign([
    'TR_PAGE_TITLE'     => tr('Client / Webtools / Protected Areas / Manage Users and Groups / Add Group'),
    'TR_HTACCESS_GROUP' => tr('Htaccess group'),
    'TR_GROUPNAME'      => tr('Group name'),
    'GROUPNAME'         => isset($_POST['groupname']) ? toHtml($_POST['groupname']) : '',
    'TR_ADD_GROUP'      => tr('Add'),
    'TR_CANCEL'         => tr('Cancel')
]);
View::generateNavigation($tpl);
generatePageMessage($tpl);
$tpl->parse('LAYOUT_CONTENT', 'page');
Application::getInstance()->getEventManager()->trigger(Events::onClientScriptEnd, NULL, ['templateEngine' => $tpl]);
$tpl->prnt();
unsetMessages();
