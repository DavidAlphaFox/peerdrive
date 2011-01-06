#!/usr/bin/env python
# vim: set fileencoding=utf-8 :
#
# Hotchpotch
# Copyright (C) 2010  Jan Klötzke <jan DOT kloetzke AT freenet DOT de>
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

from PyQt4 import QtCore, QtGui#, QtOpenGL
from datetime import datetime
import itertools

from hotchpotch import Connector, Registry, struct, connector
from hotchpotch.gui import utils
from hotchpotch.gui.widgets import DocumentView

from container import CollectionWidget, CollectionModel

class HistoryItem(object):

	def __init__(self, link, state):
		self.__link = link
		self.__text = "FIXME"
		self.__state = state

	def link(self):
		return self.__link

	def text(self):
		return self.__text

	def setText(self, text):
		self.__text = text

	def state(self):
		return self.__state


class History(QtCore.QObject):

	leaveItem = QtCore.pyqtSignal(HistoryItem)

	enterItem = QtCore.pyqtSignal(HistoryItem)

	def __init__(self):
		super(History, self).__init__()

		self.__items = []
		self.__current = -1

	def back(self):
		if self.__current > 0:
			self.leaveItem.emit(self.__items[self.__current])
			self.__current -= 1
			self.enterItem.emit(self.__items[self.__current])

	def forward(self):
		if self.__current < len(self.__items)-1:
			self.leaveItem.emit(self.__items[self.__current])
			self.__current += 1
			self.enterItem.emit(self.__items[self.__current])

	def backItems(self, maxItems):
		return self.__items[:self.__current]

	def forwardItems(self, maxItems):
		return self.__items[self.__current+1:]

	def canGoBack(self):
		return self.__current > 0

	def canGoForward(self):
		return self.__current < len(self.__items)-1

	def currentItem(self):
		return self.__items[self.__current]

	def goToItem(self, item):
		self.leaveItem.emit(self.__items[self.__current])
		self.__current = self.__items.index(item)
		self.enterItem.emit(self.__items[self.__current])

	def items(self):
		return self.__items[:]

	def push(self, link, state={}):
		if self.__current >= 0:
			self.leaveItem.emit(self.__items[self.__current])
		self.__current += 1
		self.__items[self.__current:] = [HistoryItem(link, state)]
		self.enterItem.emit(self.__items[self.__current])


class WarpProxy(QtGui.QGraphicsProxyWidget):

	def __init__(self, item, level):
		super(WarpProxy, self).__init__()
		self.__item = item
		self.__curLevel = level
		self.__newLevel = level
		self.__fadeTimeLine = QtCore.QTimeLine(250, self)
		self.__fadeTimeLine.valueChanged.connect(self.__fadeValueChanged)
		self.__fadeTimeLine.finished.connect(self.__fadeFinished)
		self.__levelTimeLine = QtCore.QTimeLine(250, self)
		self.__levelTimeLine.valueChanged.connect(self.__levelValueChanged)
		self.__levelTimeLine.finished.connect(self.__levelFinished)

		self.setOpacity(0.0)

		self.__setTransform(level)

	def setGeometry(self, geometry):
		super(WarpProxy, self).setGeometry(geometry)
		self.setTransformOriginPoint(QtCore.QPointF(geometry.width()/2,
			-geometry.height()/2))

	def fadeIn(self):
		if self.__fadeTimeLine.direction() != QtCore.QTimeLine.Forward:
			self.__fadeTimeLine.setDirection(QtCore.QTimeLine.Forward)
		if self.__fadeTimeLine.state() == QtCore.QTimeLine.NotRunning:
			self.__fadeTimeLine.start()

	def fadeOut(self):
		if self.__fadeTimeLine.direction() != QtCore.QTimeLine.Backward:
			self.__fadeTimeLine.setDirection(QtCore.QTimeLine.Backward)
		if self.__fadeTimeLine.state() == QtCore.QTimeLine.NotRunning:
			self.__fadeTimeLine.start()

	def fadeFull(self):
		if self.__fadeTimeLine.state() == QtCore.QTimeLine.Running:
			self.__fadeTimeLine.stop()
		self.__fadeTimeLine.setCurrentTime(250)
		self.__fadeValueChanged(1.0)

	def setLevel(self, level):
		if level != self.__curLevel:
			self.__newLevel = level
			if self.__levelTimeLine.state() == QtCore.QTimeLine.NotRunning:
				self.__levelTimeLine.start()

	def __fadeValueChanged(self, step):
		self.setOpacity(step)

	def __fadeFinished(self):
		if self.__fadeTimeLine.currentValue() == 0:
			self.__item._vanished()

	def __levelValueChanged(self, step):
		level = self.__curLevel + (self.__newLevel - self.__curLevel) * step
		self.__setTransform(level)

	def __setTransform(self, level):
		level = 1+level*0.2
		#tr = QtGui.QTransform()
		#tr.scale(1/level, 1/level)
		#self.setTransform(tr)
		self.setScale(1/level)
		self.setZValue(-level)

	def __levelFinished(self):
		self.__curLevel = self.__newLevel


class WarpItem(connector.Watch):

	def __init__(self, view, size, scene, rev):
		connector.Watch.__init__(self, connector.Watch.TYPE_REV, rev)
		self.__view = view
		self.__geometry = QtCore.QRectF(-size.width()/2.0, -size.height()/2.0,
			float(size.width()), float(size.height()))
		self.__scene = scene
		self.__rev = rev
		self.__widget = None
		self.__available = False
		self.__seen = False
		self.__watching = False
		self.__mtime = datetime.fromtimestamp(0)
		self.__state = {}
		self.__update()

	def setState(self, state):
		self.__state = state
		if self.__widget:
			self.__widget.widget()._loadSettings(state)

	def getState(self):
		state = {}
		if self.__widget:
			self.__widget.widget()._saveSettings(state)
		return state

	def delete(self):
		self.__unwatch()
		self._vanished()

	def getWidget(self):
		return self.__widget.widget()

	def available(self):
		return self.__available

	def rev(self):
		return self.__rev

	def mtime(self):
		return self.__mtime

	def setEnabled(self, enable):
		if self.__widget:
			self.__widget.setEnabled(enable)

	def resize(self, size):
		self.__geometry = QtCore.QRectF(-size.width()/2.0, -size.height()/2.0,
			float(size.width()), float(size.height()))
		if self.__widget:
			self.__widget.setGeometry(self.__geometry)

	def fadeIn(self, level):
		if self.__widget:
			self.__widget.setLevel(level)
		elif self.__available:
			self.__createWidget(level)
			self.__widget.fadeIn()

	def fadeFull(self, level):
		if self.__widget:
			self.__widget.setLevel(level)
		elif self.__available:
			self.__createWidget(level)
			self.__widget.fadeFull()

	def setLevel(self, level):
		if self.__widget:
			self.__widget.setLevel(level)

	def fadeOut(self):
		if self.__widget:
			self.__widget.fadeOut()

	def triggered(self, event):
		if event == connector.Watch.EVENT_DISAPPEARED:
			self.__available = False
			self.__watch()
			self.__view._update(0)
		elif event == connector.Watch.EVENT_APPEARED:
			self.__update()
			if self.__available:
				self.__view._update(0)

	def __createWidget(self, level):
		widget = CollectionWidget()
		if self.__state:
			widget._loadSettings(self.__state)
		widget.docOpen(self.__rev, False)
		widget.itemOpen.connect(self.__itemOpen)
		proxy = WarpProxy(self, level)
		proxy.setWidget(widget)
		proxy.setGeometry(self.__geometry)
		self.__widget = proxy
		self.__scene.addItem(self.__widget)
		self.__watch()

	def _vanished(self):
		if self.__widget:
			self.__widget.widget().docClose()
			self.__scene.removeItem(self.__widget)
			self.__widget = None

	def __update(self):
		if self.__seen:
			self.__unwatch()
			self.__available = len(Connector().lookup_rev(self.__rev)) > 0
		else:
			self.__available = False
			try:
				stat = Connector().stat(self.__rev)
				self.__mtime = stat.mtime()
				self.__seen = True
				self.__available = True
				self.__view._addParents(stat.parents())
				self.__unwatch()
			except IOError:
				self.__watch()
				return

	def __watch(self):
		if not self.__watching:
			Connector().watch(self)
			self.__watching = True

	def __unwatch(self):
		if self.__watching:
			Connector().unwatch(self)
			self.__watching = False

	def __itemOpen(self, link):
		self.__view._open(link)


class WarpView(QtGui.QGraphicsView):

	openItem = QtCore.pyqtSignal(struct.RevLink, object)

	def __init__(self, rev, state):
		self.__scene = QtGui.QGraphicsScene()
		super(WarpView, self).__init__(self.__scene)

		self.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
		self.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
		self.setRenderHints(self.renderHints()
			| QtGui.QPainter.Antialiasing
			| QtGui.QPainter.SmoothPixmapTransform)
		self.setBackgroundBrush(QtGui.QBrush(QtGui.QColor(0, 0, 0)))
#		self.setBackgroundBrush(QtGui.QBrush(QtGui.QPixmap("space_warp.jpg")))
#		self.setViewport(QtOpenGL.QGLWidget(QtOpenGL.QGLFormat(QtOpenGL.QGL.SampleBuffers)))

		self.__parentTimer = QtCore.QTimer(self)
		self.__parentTimer.timeout.connect(self.__inspectParents)
		self.__parentTimer.setSingleShot(True)
		self.__parentTimer.setInterval(100)
		self.__parentBacklog = []

		self.__goPast = QtGui.QPushButton("Past")
		self.__goPast.clicked.connect(self.__movePast)
		self.__goPresent = QtGui.QPushButton("Present")
		self.__goPresent.clicked.connect(self.__movePresent)
		self.__openBtn = QtGui.QPushButton("Open")
		self.__openBtn.clicked.connect(self.__open)
		self.__scene.addWidget(self.__goPast)
		self.__scene.addWidget(self.__goPresent)
		self.__scene.addWidget(self.__openBtn)

		self.__distance = 1
		self.__zoom = 1
		self.__initTimeLine = QtCore.QTimeLine(250, self)
		self.__initTimeLine.valueChanged.connect(self.__initValueChanged)
		self.__initTimeLine.start()

		item = WarpItem(self, self.size(), self.__scene, rev)
		item.fadeFull(0)
		item.setState(state)
		self.__state = state
		self.__allItems = { rev : item }
		self.__availItems = []
		self.__visibleItems = []
		self.__curItem = item
		self._update(0)

	def delete(self):
		for item in self.__allItems.values():
			item.delete()
		self.__visibleItems = []
		self.__allItems = {}
		self.__availItems = []
		self.__curItem = None

	def getCurrentView(self):
		return self.__curItem.getWidget()

	def resizeEvent(self, event):
		super(WarpView, self).resizeEvent(event)
		self.__resize()

	def _addParents(self, parents):
		self.__parentBacklog.extend(parents)
		if not self.__parentTimer.isActive():
			self.__parentTimer.start()

	def _update(self, motion):
		# sort items by time
		self.__availItems = [item for item in self.__allItems.values()
			if item.available()]
		self.__availItems.sort(key=lambda item: item.mtime(), reverse=True)
		if self.__curItem not in self.__availItems:
			self.__state = self.__curItem.getState()
			self.__curItem = self.__availItems[0] # FIXME

		old = self.__visibleItems[:]
		index = self.__availItems.index(self.__curItem)
		self.__visibleItems = self.__availItems[index:index+3]
		for (pos, item) in zip(itertools.count(0), old):
			if item not in self.__visibleItems:
				item.setEnabled(False)
				item.setLevel(pos+motion)
				item.fadeOut()
		for (pos, item) in zip(itertools.count(0), self.__visibleItems):
			if item in old:
				item.setLevel(pos)
			else:
				item.fadeIn(pos-motion)
				item.setLevel(pos)
			item.setEnabled(pos == 0)
			item.setState(self.__state)

		self.__goPast.setEnabled(index < len(self.__availItems)-1)
		self.__goPresent.setEnabled(index > 0)

	def __inspectParents(self):
		trigger = False
		todo = self.__parentBacklog[0:3]
		del self.__parentBacklog[0:3]

		for rev in todo:
			if rev not in self.__allItems:
				self.__allItems[rev] = WarpItem(self, self.size()*self.__distance, self.__scene, rev)
				trigger = True

		if trigger:
			self._update(0)
		if self.__parentBacklog and not self.__parentTimer.isActive():
			self.__parentTimer.start()

	def __resize(self):
		size = self.size()
		offset = size.height() * self.__zoom
		self.setSceneRect(
			-size.width()/2,
			-size.height()/2-offset,
			size.width()-2,
			size.height()-2)
		h = self.__goPast.height()
		self.__openBtn.move(size.width()/2-self.__openBtn.width()-2,
			self.height()/2-3*h-2-offset)
		self.__goPast.move(size.width()/2-self.__goPast.width()-2,
			self.height()/2-2*h-2-offset)
		self.__goPresent.move(size.width()/2-self.__goPresent.width()-2,
			self.height()/2-h-2-offset)

		size = self.size() * self.__distance
		for item in self.__allItems.values():
			item.resize(size)

	def __initValueChanged(self, step):
		self.__zoom = (0.25/4)*step
		self.__distance = 1 - 0.25*step
		self.__resize()

	def __movePast(self):
		self.__state = self.__curItem.getState()
		self.__curItem = self.__visibleItems[1]
		self._update(-1)

	def __movePresent(self):
		self.__state = self.__curItem.getState()
		index = self.__availItems.index(self.__curItem)
		self.__curItem = self.__availItems[index-1]
		self._update(1)

	def __open(self):
		self.__state = self.__curItem.getState()
		self._open(struct.RevLink(self.__curItem.rev()), self.__state)

	def _open(self, link, state={}):
		try:
			type = Connector().stat(link.rev()).type()
			if type in ["org.hotchpotch.dict", "org.hotchpotch.store", "org.hotchpotch.set"]:
				self.__initTimeLine.setDirection(QtCore.QTimeLine.Backward)
				self.__initTimeLine.finished.connect(
					lambda l=link, s=state: self.openItem.emit(l, s))
				self.__initTimeLine.start()
			else:
				self.openItem.emit(link, state)
		except IOError:
			pass


class BrowserWindow(QtGui.QMainWindow):

	def __init__(self):
		QtGui.QMainWindow.__init__(self)
		self.setAttribute(QtCore.Qt.WA_DeleteOnClose)

		self.__view = CollectionWidget()
		self.__view.itemOpen.connect(self.__itemOpen)
		self.__view.revChanged.connect(self.__extractMetaData)
		self.__view.selectionChanged.connect(self.__selectionChanged)
		self.setCentralWidget(self.__view)

		self.__history = History()
		self.__history.leaveItem.connect(self.__leaveItem)
		self.__history.enterItem.connect(self.__enterItem)

		self.__backMenu = QtGui.QMenu()
		self.__backMenu.aboutToShow.connect(self.__showBackMenu)
		self.__backAct = QtGui.QAction(QtGui.QIcon('icons/back.png'), "Back", self)
		self.__backAct.setMenu(self.__backMenu)
		self.__backAct.triggered.connect(self.__history.back)
		self.__forwardMenu = QtGui.QMenu()
		self.__forwardMenu.aboutToShow.connect(self.__showForwardMenu)
		self.__forwardAct = QtGui.QAction(QtGui.QIcon('icons/forward.png'), "Forward", self)
		self.__forwardAct.setMenu(self.__forwardMenu)
		self.__forwardAct.triggered.connect(self.__history.forward)
		self.__exitAct = QtGui.QAction("Close", self)
		self.__exitAct.setShortcut("Ctrl+Q")
		self.__exitAct.setStatusTip("Close the document")
		self.__exitAct.triggered.connect(self.close)

		self.__warpAct = QtGui.QAction("TimeWarp", self)
		self.__warpAct.setCheckable(True)
		self.__warpAct.toggled.connect(self.__warp)

		self.__browseToolBar = self.addToolBar("Browse")
		self.__browseToolBar.addAction(self.__backAct)
		self.__browseToolBar.addAction(self.__forwardAct)
		self.__browseToolBar.addAction(self.__warpAct)

		self.__fileMenu = self.menuBar().addMenu("File")
		self.__fileMenu.aboutToShow.connect(self.__showFileMenu)
		self.__colMenu = self.menuBar().addMenu("Columns")
		self.__colMenu.aboutToShow.connect(self.__columnsShow)

	def closeEvent(self, event):
		super(BrowserWindow, self).closeEvent(event)
		self.__view.checkpoint("<<Changed by browser>>")

	def open(self, argv):
		# parse command line
		if len(argv) == 2 and argv[1].startswith('doc:'):
			guid = argv[1][4:].decode("hex")
			isDoc = True
		elif len(argv) == 2 and argv[1].startswith('rev:'):
			guid = argv[1][4:].decode("hex")
			isDoc = False
		elif len(argv) == 2:
			link = struct.resolvePath(argv[1])
			if isinstance(link, struct.DocLink):
				guid = link.doc()
				isDoc = True
			else:
				guid = link.rev()
				isDoc = False
		else:
			print "Usage: %s <Document>" % (sys.argv[0])
			print
			print "Document:"
			print "    doc:<document>  ...open the latest version of the given document"
			print "    rev:<revision>  ...display the given revision"
			print "    <hp-path-spec>  ...open by path spec"
			sys.exit(1)

		# open the document
		if isDoc:
			self.__history.push(struct.DocLink(guid, False))
		else:
			self.__history.push(struct.RevLink(guid))

	def __extractMetaData(self):
		caption = self.__view.metaDataGetField(DocumentView.HPA_TITLE, "Unnamed")
		if not self.__view.doc() and self.__view.rev():
			try:
				mtime = Connector().stat(self.__view.rev()).mtime()
				caption = caption + " @ " + str(mtime)
			except IOError:
				pass
		self.__history.currentItem().setText(caption)
		self.setWindowTitle(caption)

	def __itemOpen(self, link, state={}):
		link.update()
		revs = link.revs()
		if len(revs) == 0:
			return False
		ret = False
		try:
			type = Connector().stat(revs[0]).type()
			if type in ["org.hotchpotch.dict", "org.hotchpotch.store", "org.hotchpotch.set"]:
				self.__history.push(link, state)
				ret = True
			else:
				utils.showDocument(link)
		except IOError:
			pass
		return ret

	def __leaveItem(self, item):
		if self.__warpAct.isChecked():
			self.__warpAct.setChecked(False)
		self.__view.checkpoint("<<Changed by browser>>")
		self.__view._saveSettings(item.state())

	def __enterItem(self, item):
		self.__view._loadSettings(item.state())
		link = item.link()
		if isinstance(link, struct.DocLink):
			self.__view.docOpen(link.doc(), True)
		else:
			self.__view.docOpen(link.rev(), False)

		self.__backAct.setEnabled(self.__history.canGoBack())
		self.__forwardAct.setEnabled(self.__history.canGoForward())

	def __showBackMenu(self):
		self.__backMenu.clear()
		items = self.__history.backItems(10)[:]
		items.reverse()
		for item in items:
			action = self.__backMenu.addAction(item.text())
			action.triggered.connect(lambda x,item=item: self.__history.goToItem(item))

	def __showForwardMenu(self):
		self.__forwardMenu.clear()
		for item in self.__history.forwardItems(10):
			action = self.__forwardMenu.addAction(item.text())
			action.triggered.connect(lambda x,item=item: self.__history.goToItem(item))

	def __activeView(self):
		if self.__warpAct.isChecked():
			return self.centralWidget().getCurrentView()
		else:
			return self.__view

	def __showFileMenu(self):
		self.__fileMenu.clear()
		self.__activeView().fillContextMenu(self.__fileMenu)
		self.__fileMenu.addSeparator()
		self.__fileMenu.addAction(self.__exitAct)

	def __columnsShow(self):
		self.__colMenu.clear()
		reg = Registry()
		model = self.__activeView().model()
		types = model.typeCodes().copy()
		columns = model.getColumns()
		for col in columns:
			(uti, path) = col.split(':')
			if uti != "":
				types.add(uti)
		# add stat columns
		self.__columnsShowAddEntry(self.__colMenu, columns, ":size", "Size")
		self.__columnsShowAddEntry(self.__colMenu, columns, ":mtime", "Modification time")
		self.__columnsShowAddEntry(self.__colMenu, columns, ":type", "Type code")
		self.__columnsShowAddEntry(self.__colMenu, columns, ":creator", "Creator code")
		self.__colMenu.addSeparator()
		# add meta columns
		metaSpecs = {}
		for t in types:
			metaSpecs.update(reg.searchAll(t, "meta"))
		for (uti, specs) in metaSpecs.items():
			subMenu = self.__colMenu.addMenu(reg.getDisplayString(uti))
			for spec in specs:
				key = uti+":"+reduce(lambda x,y: x+"/"+y, spec["key"])
				self.__columnsShowAddEntry(subMenu, columns, key, spec["display"])

	def __columnsShowAddEntry(self, subMenu, columns, key, display):
		model = self.__activeView().model()
		visible = key in columns
		action = subMenu.addAction(display)
		action.setCheckable(True)
		action.setChecked(visible)
		if visible:
			action.triggered.connect(lambda en, col=key: model.remColumn(col))
		else:
			action.triggered.connect(lambda en, col=key: model.addColumn(col))

	def __selectionChanged(self):
		selected = self.__view.getSelectedLinks()
		self.statusBar().showMessage("%d item(s) selected" % len(selected))

	def __warp(self, checked):
		if checked:
			state = {}
			self.__view.checkpoint("<<Changed by browser>>")
			self.__view.setParent(None)
			self.__view._saveSettings(state)
			warp = WarpView(self.__view.rev(), state)
			warp.openItem.connect(self.__warpOpen)
			self.setCentralWidget(warp)
		else:
			self.centralWidget().delete()
			self.setCentralWidget(self.__view)

	def __warpOpen(self, link, state):
		if self.__itemOpen(link, state):
			self.__warpAct.setChecked(False)


class BreadcrumBar(QtGui.QWidget):

	def __init__(self, parent=None):
		super(BreadcrumBar, self).__init__()
		self.__history = None

	def setHistory(self, history):
		self.__history = history
		self.__history.navigated.connect(self.__navigated)
		self.__history.changed.connect(self.__changed)

	def __navigated(self):
		pass

	def __changed(self):
		pass


if __name__ == '__main__':

	import sys

	app = QtGui.QApplication(sys.argv)
	mainWin = BrowserWindow()
	mainWin.open(sys.argv)
	mainWin.show()
	sys.exit(app.exec_())

