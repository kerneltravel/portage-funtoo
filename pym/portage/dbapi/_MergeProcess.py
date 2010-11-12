# Copyright 2010 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2

import portage
from portage import os
from _emerge.SpawnProcess import SpawnProcess

class MergeProcess(SpawnProcess):
	"""
	Merge package files in a subprocess, so the Scheduler can run in the
	main thread while files are moved or copied asynchronously.
	"""

	__slots__ = ('cfgfiledict', 'conf_mem_file', \
		'destroot', 'dblink', 'srcroot',)

	def _spawn(self, args, fd_pipes=None, **kwargs):
		"""
		Fork a subprocess, apply local settings, and call
		dblink._merge_process().
		"""

		pid = os.fork()
		if pid != 0:
			portage.process.spawned_pids.append(pid)
			return [pid]

		portage.process._setup_pipes(fd_pipes)

		portage.output.havecolor = self.dblink.settings.get('NOCOLOR') \
			not in ('yes', 'true')

		# In this subprocess we want dblink._display_merge() to use
		# stdout/stderr directly since they are pipes. This behavior
		# is triggered when dblink._scheduler is None.
		self.dblink._scheduler = None

		rval = self.dblink._merge_process(self.srcroot, self.destroot,
			self.cfgfiledict, self.conf_mem_file)

		os._exit(rval)
