# vim: set fileencoding=utf-8 :
#
# PeerDrive
# Copyright (C) 2011  Jan Klötzke <jan DOT kloetzke AT freenet DOT de>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

from __future__ import absolute_import

import os
from .connector import Connector
from .registry  import Registry

_settingsPath = None

def settingsPath():
	global _settingsPath
	if not _settingsPath:
		for e in ['HOME', 'LOCALAPPDATA', 'APPDATA']:
			if e in os.environ:
				_settingsPath = os.path.join(os.environ[e], '.peerdrive')
				break
	return _settingsPath

