const {test} = require('node:test')
const assert = require('node:assert/strict')
global.Quickshell = {env: () => '/tmp/test'}
const Config = require('../WidgetConfig.js')
const Profiles = require('../LayoutProfiles.js')
const Layout = require('../WidgetLayout.js')
test('monitor topology uses geometry and scaling, independent of enumeration order', () => {
  const a = {name:'eDP-1',width:1280,height:720,scale:1.5,x:0,y:0}
  const b = {name:'DP-1',width:1920,height:1080,scale:1,x:1280,y:0}
  assert.equal(Profiles.topologyKey([a,b]),Profiles.topologyKey([b,a]))
  assert.notEqual(Profiles.topologyKey([a]),Profiles.topologyKey([{...a,scale:1}]))
  assert.notEqual(Profiles.profileKey([a,b],'DP-1'),Profiles.profileKey([a,b],'eDP-1'))
})
test('undocking and redocking restores exact layouts without overwriting other preferences', () => {
  let c = Config.defaultConfig(); c.widgets.media.x=450; c.widgets.media.y=200
  c = Profiles.switchProfile(c,'','laptop')
  c = Profiles.switchProfile(c,'laptop','docked')
  c.widgets.media.x=1400; c.widgets.media.cardWidth=400; c.widgets.media.showAlbumArt=false
  c = Profiles.switchProfile(c,'docked','laptop')
  assert.equal(c.widgets.media.x,450); assert.equal(c.widgets.media.cardWidth,0)
  assert.equal(c.widgets.media.showAlbumArt,false)
  c = Profiles.switchProfile(c,'laptop','docked')
  assert.equal(c.widgets.media.x,1400); assert.equal(c.widgets.media.cardWidth,400)
})
test('named layouts save, restore and delete without replacing theme or GPU selection', () => {
  let c=Config.defaultConfig(); c.widgets.media.x=600
  c=Profiles.named(c,'Work','save'); c.widgets.media.x=50; c.themeMode='custom'; c.widgets.systemMonitor.gpuDevice='pci'
  c=Profiles.named(c,'Work','load')
  assert.equal(c.widgets.media.x,600); assert.equal(c.themeMode,'custom'); assert.equal(c.widgets.systemMonitor.gpuDevice,'pci')
  c=Profiles.named(c,'Work','delete'); assert.deepEqual(c.namedLayouts,{})
  assert.equal(Profiles.named(c,'__proto__','save'),c)
})
test('layout restore ignores invalid fields and does not mutate input', () => {
  const c=Config.defaultConfig(), copy=JSON.stringify(c)
  const n=Profiles.apply(c,{widgets:{media:{x:NaN,y:90,cardWidth:999,showAlbumArt:false}},cardSpacing:100})
  assert.equal(n.widgets.media.x,-1); assert.equal(n.widgets.media.y,90); assert.equal(n.widgets.media.cardWidth,500)
  assert.equal(n.widgets.media.showAlbumArt,true); assert.equal(n.global.cardSpacing,24); assert.equal(JSON.stringify(c),copy)
})
const bounds={left:0,top:40,right:1200,bottom:800}
test('snaps to grid and clamps to the work area', () => {
  const p=Layout.snapPosition({x:19,y:53,width:200,height:100},[],bounds,{snapToGrid:true})
  assert.equal(p.x,16); assert.equal(p.y,56)
  const edge=Layout.snapPosition({x:1199,y:799,width:200,height:100},[],bounds,{snapToGrid:true})
  assert.equal(edge.x,1000); assert.equal(edge.y,700)
})
test('card gap and alignment guides take precedence over grid', () => {
  const p=Layout.snapPosition({x:416,y:102,width:200,height:100},[{x:100,y:100,width:300,height:100}],bounds,{snapToGrid:true,snapToCards:true,gap:12})
  assert.equal(p.x,412); assert.equal(p.y,100); assert.equal(p.guideX,412); assert.equal(p.guideY,100)
})
test('disabled snapping keeps exact free placement', () => {
  const p=Layout.snapPosition({x:19,y:53,width:200,height:100},[],bounds,{})
  assert.equal(p.x,19); assert.equal(p.y,53); assert.equal(p.guideX,-1)
})
