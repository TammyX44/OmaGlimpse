import pathlib,tempfile,shutil,subprocess,os
import unittest, sys

def run_fixture():
    repo=pathlib.Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='omawidgets-mpris-integration-') as directory:
     stage=pathlib.Path(directory)
     for file in repo.iterdir():
      if file.suffix in ['.qml','.js','.py']: shutil.copy2(file,stage/file.name)
     for folder in ['Commons','Ui']: (stage/folder).symlink_to('/usr/share/omarchy/shell/'+folder)
     (stage/'runtime').mkdir(mode=0o700)
     (stage/'shell.qml').write_text('''import QtQuick
    import QtTest
    import Quickshell
    import "." as Plugin
    ShellRoot {
     id: suite
     property bool ready: false
     Timer { interval: 300; running: true; onTriggered: suite.ready = true }
     FloatingWindow {
     visible: true; implicitWidth: 500; implicitHeight: 300
     Plugin.MediaWidget { id: card }
     Timer { interval: 100; repeat: true; running: card.activePlayer !== null
       onTriggered: card.activePlayer.positionChanged() }
     TestCase {
     name: "LiveMpris"; when: suite.ready
     function test_live() {
     tryVerify(function() { return card.activePlayer !== null }, 3000)
    
     tryVerify(function() { return card.timingSnapshot !== null }, 3000)
     console.log("FIRST_SAMPLE", JSON.stringify(card.timingSnapshot))
     tryCompare(card, "trackLength", 20, 7000)
     verify(card.livePosition < 5)
     console.log("LIVE_MPRIS_PASS")
     }
     function cleanupTestCase() { console.log("LIVE_MPRIS_FAILURES", qtest_results.failCount) }
     }
     }
    }''')
     server=subprocess.Popen(['/usr/bin/python',str(repo/'tests/mpris-fixture.py')])
     try:
      result=subprocess.run(['qs','--no-color','-p',str(stage/'shell.qml')],env={**os.environ,'XDG_RUNTIME_DIR':str(stage/'runtime'),'QT_QPA_PLATFORM':'offscreen','QT_QPA_PLATFORMTHEME':'basic','QT_QUICK_BACKEND':'software'},capture_output=True,text=True,timeout=20)
      output = result.stdout+result.stderr
      print(output)
      assert result.returncode == 0, output
      assert "LIVE_MPRIS_PASS" in output and "LIVE_MPRIS_FAILURES 0" in output, output
     finally:
      server.terminate();server.wait()


class MprisIntegrationTests(unittest.TestCase):
    def test_real_dbus_silent_repeat_and_duration(self):
        if not shutil.which('qs') or not shutil.which('dbus-run-session') or not pathlib.Path('/usr/share/omarchy/shell/Commons').exists():
            self.skipTest('Quickshell, D-Bus and Omarchy modules required')
        if subprocess.run(['/usr/bin/python', '-c', 'from gi.repository import Gio, GLib'], capture_output=True).returncode:
            self.skipTest('System Python GObject bindings required for private MPRIS fixture')
        result = subprocess.run(['dbus-run-session', '--', sys.executable, __file__, '--fixture'],
                                capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    if '--fixture' in sys.argv:
        run_fixture()
    else:
        unittest.main()
