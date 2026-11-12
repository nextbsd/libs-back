/*
   NextBSDServer+TiledFrames - keep saved window frames out of tiling

   Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>

   This file is part of the GNU Objective C Backend Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; see the file COPYING.LIB.
   If not, see <http://www.gnu.org/licenses/> or write to the
   Free Software Foundation, 51 Franklin Street, Fifth Floor,
   Boston, MA 02110-1301, USA.
*/

/*
 * Saved window frames while WindowServer tiles (WS_SERVER_TILING).
 *
 * libs-gui saves a window's frame under its autosave name ("NSWindow
 * Frame <name>" in the app's defaults) whenever the window moves or is
 * resized, the backend's GSAppKitWindowMoved and GSAppKitWindowResized
 * included. A tile is WindowServer's choice, not the user's: saving it
 * would bring the window back at its tile's size the next time the app
 * opens it, in stacking too.
 *
 * WindowServer marks a tile's frame with WS_FRAME_TILED, and gives the
 * window its frame from before tiling back without it. When a window
 * gets its first tile, the backend remembers what its autosave name had
 * saved (or that nothing was). While it's tiled, each time libs-gui
 * saves its frame (it posts NSWindowDidMoveNotification or
 * NSWindowDidResizeNotification right after, whether the change came from
 * the server or from the app), the backend puts the remembered frame
 * back. That goes on after tiling ends, until the app places the window
 * itself (the user moves or resizes it): the frame WindowServer gives
 * back is the one the window had on screen, which may have had another
 * menu style's height (a window opened while tiling, with in-window
 * menus), while libs-gui's saved frame leaves the menu out. libs-gui is
 * unchanged.
 */

#include "config.h"
#include <AppKit/NSGraphics.h>
#include <AppKit/NSWindow.h>
#include <Foundation/NSDictionary.h>
#include <Foundation/NSNotification.h>
#include <Foundation/NSNull.h>
#include <Foundation/NSString.h>
#include <Foundation/NSUserDefaults.h>
#include <Foundation/NSValue.h>
#include <GNUstepGUI/GSDisplayServer.h>

#include "nextbsd/NextBSDServer.h"

/* libs-gui's key for a saved frame (-[NSWindow saveFrameUsingName:]). */
static NSString *
savedFrameKey(NSWindow *nswin)
{
  NSString *name = [nswin frameAutosaveName];

  if ([name length] == 0)
    return nil;
  return [NSString stringWithFormat: @"NSWindow Frame %@", name];
}

@implementation NextBSDServer (TiledFrames)

- (void) _setUpTiledFrames
{
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

  [nc addObserver: self
	 selector: @selector(_keepUntiledFrame:)
	     name: NSWindowDidMoveNotification
	   object: nil];
  [nc addObserver: self
	 selector: @selector(_keepUntiledFrame:)
	     name: NSWindowDidResizeNotification
	   object: nil];
}

/* The entry for a window: its saved frame from before tiling (or
   NSNull), and whether it's tiled now. */
static NSString *const SavedKey = @"saved";
static NSString *const TiledKey = @"tiled";

- (void) _window: (nextbsd_window_t *)w isTiled: (BOOL)tiled
{
  NSNumber	      *number = [NSNumber numberWithInt: w->number];
  NSMutableDictionary *entry = [tiledFrames objectForKey: number];
  NSString	      *key;
  id		       saved;

  if (entry != nil)
    {
      [entry setObject: [NSNumber numberWithBool: tiled] forKey: TiledKey];
      return;
    }
  if (!tiled)
    return;
  /* Its first tile: libs-gui hasn't seen it yet (the frame event is
     queued), so the defaults still have the frame from before. */
  key = savedFrameKey(GSWindowWithNumber(w->number));
  saved = key != nil
    ? [[NSUserDefaults standardUserDefaults] objectForKey: key] : nil;
  if (tiledFrames == nil)
    tiledFrames = [[NSMutableDictionary alloc] init];
  entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
    (saved != nil ? saved : [NSNull null]), SavedKey,
    [NSNumber numberWithBool: YES], TiledKey, nil];
  [tiledFrames setObject: entry forKey: number];
}

- (void) _windowPlacedByApp: (int)win
{
  NSNumber *number = [NSNumber numberWithInt: win];

  if (![[[tiledFrames objectForKey: number] objectForKey: TiledKey] boolValue])
    [tiledFrames removeObjectForKey: number];
}

- (void) _windowClosed: (int)win
{
  [tiledFrames removeObjectForKey: [NSNumber numberWithInt: win]];
}

/* libs-gui just saved a tiled window's frame (or one tiled until now):
   put the old one back. */
- (void) _keepUntiledFrame: (NSNotification *)n
{
  NSWindow	 *nswin = [n object];
  NSUserDefaults *defs;
  NSString	 *key;
  id		  saved;

  if ([tiledFrames count] == 0 || ![nswin isKindOfClass: [NSWindow class]])
    return;
  saved = [[tiledFrames objectForKey:
		     [NSNumber numberWithInt: [nswin windowNumber]]]
	    objectForKey: SavedKey];
  key = savedFrameKey(nswin);
  if (saved == nil || key == nil)
    return;
  defs = [NSUserDefaults standardUserDefaults];
  if (saved == [NSNull null])
    {
      if ([defs objectForKey: key] != nil)
	[defs removeObjectForKey: key];
    }
  else if (![[defs objectForKey: key] isEqual: saved])
    {
      [defs setObject: saved forKey: key];
    }
}

@end
