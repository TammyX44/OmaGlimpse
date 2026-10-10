// Compare the seven-card workload with the previous Git revision. This is
// an offscreen workload benchmark, not a whole-desktop or energy benchmark.
// No power profile, lock, DPMS state or saved preference is changed.
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { execFileSync, spawn } = require('node:child_process')
const repo = path.resolve(__dirname, '..')
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'omaglimpse-benchmark-'))
const ticks = Number(execFileSync('getconf', ['CLK_TCK'], {encoding:'utf8'}).trim())

function reading(pid) {
  const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8')
  const fields = stat.slice(stat.lastIndexOf(')') + 2).split(/\s+/)
  let switches = 0
  for (const tid of fs.readdirSync(`/proc/${pid}/task`)) {
    try {
      const status = fs.readFileSync(`/proc/${pid}/task/${tid}/status`, 'utf8')
      switches += Number(status.match(/^voluntary_ctxt_switches:\s*(\d+)/m)?.[1] || 0)
    } catch (_) { /* a worker thread may finish between enumeration and read */ }
  }
  const memory = fs.readFileSync(`/proc/${pid}/smaps_rollup`, 'utf8')
  return {time: performance.now(), cpu: fields.slice(11,15).reduce((n,x)=>n+Number(x),0),
    switches, pssMiB: Number(memory.match(/^Pss:\s*(\d+)/m)[1])/1024}
}

function qml(modern) {
  const props = modern ? 'samplingEnabled: root.phase !== "paused" && policy.samplingEnabled; samplingMultiplier: root.phase === "saver" ? 3 : 1;' : ''
  return `import QtQuick
import Quickshell
import "." as Plugin
import "WidgetConfig.js" as Config
ShellRoot {
 id: root
 property string phase: "warming"
 property int index: 0
 property var phases: ["normal", "saver", "paused", "done"]
 property var testConfig: { var c=Config.defaultConfig(); Config.allWidgetIds().forEach(function(id){c.widgets[id].enabled=true}); return c }
 ${modern ? 'Plugin.SamplingPolicy { id: policy; enabled: root.phase !== "paused" }' : ''}
 Plugin.GpuMonitor { id: gpu; config: root.testConfig; ${props} }
 Timer { interval: 3000; running:true; onTriggered:{root.phase="normal";console.log("BENCH_PHASE normal");phasesTimer.start()} }
 Timer { id: phasesTimer; interval:10000; repeat:true; onTriggered:{
  root.index++;root.phase=root.phases[root.index];console.log("BENCH_PHASE "+root.phase)
  if(root.phase==="done"){stop();quitTimer.start()}
 } }
 Timer { id: quitTimer; interval:500; onTriggered:Qt.quit() }
 FloatingWindow {
  visible:true;implicitWidth:1200;implicitHeight:1000
  Plugin.SystemMonitor { config:root.testConfig;gpuMonitor:gpu;${props} }
  Plugin.BatteryWidget { x:500;config:root.testConfig;${props} }
  Plugin.MediaWidget { y:250;config:root.testConfig;${props} }
  Plugin.TopProcesses { x:500;y:250;config:root.testConfig;${props} }
  Plugin.NetworkSpeed { y:520;config:root.testConfig;${props} }
  Plugin.DiskUsage { x:500;y:520;config:root.testConfig;${props} }
  Plugin.Temperature { y:800;config:root.testConfig;gpuMonitor:gpu;${props} }
 }
}`
}

async function run(label, modern) {
  const directory = path.join(stage,label)
  fs.mkdirSync(directory)
  if (modern) {
    for (const name of fs.readdirSync(repo).filter(n=>/\.(qml|js|sh|py)$/.test(n)))
      fs.symlinkSync(path.join(repo,name),path.join(directory,name))
  } else {
    const archive = execFileSync('git',['archive',process.env.BENCH_BASE_REF || 'HEAD','*.qml','*.js','*.sh','*.py'],{cwd:repo,maxBuffer:10*1024*1024})
    execFileSync('tar',['-x','-C',directory],{input:archive})
  }
  const shell = process.env.OMARCHY_SHELL_DIR || '/usr/share/omarchy/shell'
  for (const module of ['Commons','Ui']) fs.symlinkSync(path.join(shell,module),path.join(directory,module))
  fs.writeFileSync(path.join(directory,'shell.qml'),qml(modern))
  return new Promise((resolve,reject)=>{
    const child = spawn('qs',['--no-color','-p',path.join(directory,'shell.qml')],{
      env:{...process.env,QT_QPA_PLATFORM:'offscreen',QT_QPA_PLATFORMTHEME:'basic',QT_QUICK_BACKEND:'software'}})
    let buffer='', output='', previous=null, phase=null, results=[]
    const deadline=setTimeout(()=>{child.kill('SIGTERM');reject(new Error(label+' benchmark timed out:\n'+output))},45000)
    child.stdout.on('data',consume);child.stderr.on('data',consume)
    function consume(chunk) {
      output+=chunk;buffer+=chunk
      let newline
      while((newline=buffer.indexOf('\n'))!==-1) {
        const line=buffer.slice(0,newline);buffer=buffer.slice(newline+1)
        const match=line.match(/BENCH_PHASE (normal|saver|paused|done)/)
        if(!match)continue
        try {
          const current=reading(child.pid)
          if(previous)results.push({phase,cpuPercentOneCore:+((current.cpu-previous.cpu)/ticks/((current.time-previous.time)/1000)*100).toFixed(2),
            pssMiB:+current.pssMiB.toFixed(2),voluntaryContextSwitches:Math.max(0,current.switches-previous.switches)})
          previous=current;phase=match[1]
        } catch(error){reject(error);child.kill('SIGTERM')}
      }
    }
    child.on('error',reject)
    child.on('exit',code=>{
      clearTimeout(deadline)
      if(code!==0 || results.length!==3 || /ReferenceError|TypeError|Failed to load configuration|Binding loop|Unable to assign/.test(output))
        reject(new Error(label+' failed:\n'+output))
      else resolve({label,results})
    })
  })
}

;(async()=>{
  try {
    console.log(JSON.stringify(await run('previous',false)))
    console.log(JSON.stringify(await run('updated',true)))
    console.log('CPU includes reaped child CPU. PSS covers the main process. Context switches are not a count of kernel wakeups. Saver and paused states are simulated; the policy continues bounded state checks. Each phase is ten seconds, with three seconds of startup excluded.')
  } finally {fs.rmSync(stage,{recursive:true,force:true})}
})().catch(error=>{console.error(error.message);process.exitCode=1})
