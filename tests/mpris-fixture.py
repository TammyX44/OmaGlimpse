from gi.repository import Gio, GLib
import time
start = time.monotonic()
root_props = {'CanQuit':('b',False),'CanRaise':('b',False),'HasTrackList':('b',False),'Identity':('s','Repeat fixture'),'DesktopEntry':('s','repeat-fixture'),'SupportedUriSchemes':('as',[]),'SupportedMimeTypes':('as',[])}
player_props = {'PlaybackStatus':('s','Playing'),'LoopStatus':('s','Track'),'Rate':('d',1.0),'Shuffle':('b',False),'Volume':('d',1.0),'MinimumRate':('d',1.0),'MaximumRate':('d',1.0),'CanGoNext':('b',True),'CanGoPrevious':('b',True),'CanPlay':('b',True),'CanPause':('b',True),'CanSeek':('b',True),'CanControl':('b',True),'Position':('x',0),'Metadata':('a{sv}',{})}
connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
for interface, props in [('org.mpris.MediaPlayer2',root_props),('org.mpris.MediaPlayer2.Player',player_props)]:
 xml='<node><interface name="'+interface+'">'+''.join('<property name="'+k+'" type="'+v[0]+'" access="read"/>' for k,v in props.items())+'</interface></node>'
 info=Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
 def get_property(conn,sender,path,iface,name):
  values=root_props if iface=='org.mpris.MediaPlayer2' else player_props
  if name=='Position': return GLib.Variant('x',9500000 if time.monotonic()-start<4 else 200000)
  if name=='Metadata': return GLib.Variant('a{sv}',{'xesam:title':GLib.Variant('s','Same track'), 'mpris:trackid':GLib.Variant('o','/track/1'), 'mpris:length':GLib.Variant('x',10000000 if time.monotonic()-start<4 else 20000000)})
  signature,value=values[name]
  return GLib.Variant(signature,value)
 connection.register_object('/org/mpris/MediaPlayer2',info,None,get_property,None)
Gio.bus_own_name_on_connection(connection,'org.mpris.MediaPlayer2.repeatfixture',Gio.BusNameOwnerFlags.NONE,None,None)
GLib.MainLoop().run()
