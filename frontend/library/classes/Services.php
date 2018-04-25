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

/**
 * Class Services
 * @package iMSCP
 */
class Services implements \iterator, \countable
{
    /**
     * @var array[] Array of services where keys are service names and values are arrays containing service properties
     */
    private $services = [];

    /**
     * @var string Service name currently queried
     */
    private $queriedService = NULL;

    /**
     * @var \Zend\Cache\Storage\StorageInterface $cache
     */
    private $cache;

    /**
     * Constructor
     */
    public function __construct()
    {
        $this->cache = Application::getInstance()->getCache();
        $values = Application::getInstance()->getDbConfig()->getArrayCopy();

        // Gets list of services port names
        $services = array_filter(
            array_keys($values),
            function ($name) {
                return (strlen($name) > 5 && substr($name, 0, 5) == 'PORT_');
            }
        );

        foreach ($services as $name) {
            $this->services[$name] = explode(';', $values[$name]);
        }
    }

    /**
     * Check if the service is visible
     *
     * @return bool TRUE if the service is visible, FALSE otherwise
     */
    public function isVisible()
    {
        return (bool)$this->getProperty(3);
    }

    /**
     * Get a service property value
     *
     * @param int $index Service property index
     * @return mixed Service property value
     */
    private function getProperty($index)
    {
        if (!is_null($this->queriedService)) {
            return $this->services[$this->queriedService][$index];
        } else {
            throw new \Exception('Name of service to query is not set');
        }
    }

    /**
     * Check if a service is running
     *
     * @param bool $refresh Flag indicating whether or not cached values must be refreshed
     * @return bool return TRUE if the service is currently running, FALSE otherwise
     */
    public function isRunning($refresh = false)
    {
        return $this->getStatus($refresh);
    }

    /**
     * Get service status
     *
     * @param bool $refresh Flag indicating whether or not cached values must be refreshed
     * @return bool TRUE if the service is currently running, FALSE otherwise
     */
    private function getStatus($refresh = false)
    {
        $identifier = __CLASS__ . '_' . __FUNCTION__ . '_' . preg_replace('/[^a-zA-Z0-9_]/', '_', $this->getName());

        if ($refresh || !$this->cache->hasItem($identifier)) {
            $ip = $this->getIp();

            if (Net::getVersion() == 6) {
                $ip = '[' . $ip . ']';
            }

            $status = false;
            if (($fp = @fsockopen($this->getProtocol() . '://' . $ip, $this->getPort(), $errno, $errstr, 0.5))) {
                fclose($fp);
                $status = true;
            }

            $this->cache->setItem($identifier, $status, [], 1200);
        } else {
            $status = $this->cache->getItem($identifier);
        }

        return (bool)$status;
    }

    /**
     * Get service name
     *
     * @return string
     */
    public function getName()
    {
        return $this->getProperty(2);
    }

    /**
     * Get service IP
     *
     * @return array
     */
    public function getIp()
    {
        return $this->getProperty(4);
    }

    /**
     * Get service protocol
     *
     * @return string
     */
    public function getProtocol()
    {
        return $this->getProperty(1);
    }

    /**
     * Get service listening port
     *
     * @return int
     */
    public function getPort()
    {
        return $this->getProperty(0);
    }

    /**
     * Check if a service is down
     *
     * @param bool $refresh Flag indicating whether or not cached values must be refreshed
     * @return bool return TRUE if the service is currently down, FALSE otherwise
     */
    public function isDown($refresh = false)
    {
        return !$this->getStatus($refresh);
    }

    /**
     * @inheritdoc
     */
    public function current()
    {
        $this->setService($this->key(), false);

        return current($this->services);
    }

    /**
     * Set service to be queried
     *
     * @param  string $serviceName Service name
     * @param  bool $normalize Tell whether or not the service name must be normalized
     * @return void
     */
    public function setService($serviceName, $normalize = true)
    {
        // Normalise service name (ex. 'dns' to 'PORT_DNS')
        if ($normalize) {
            $serviceName = 'PORT_' . strtoupper($serviceName);
        }

        if (array_key_exists($serviceName, $this->services)) {
            $this->queriedService = $serviceName;
        } else {
            throw new \Exception("Unknown Service: $serviceName");
        }
    }

    /**
     * @inheritdoc
     */
    public function key()
    {
        return key($this->services);
    }

    /**
     * @inheritdoc
     */
    public function next()
    {
        next($this->services);
    }

    /**
     * @inheritdoc
     */
    public function rewind()
    {
        reset($this->services);
    }

    /**
     * @inheritdoc
     */
    public function valid()
    {
        return array_key_exists(key($this->services), $this->services);
    }

    /**
     * @inheritdoc
     */
    public function count()
    {
        return count($this->services);
    }
}
