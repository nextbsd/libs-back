/*
   NextBSDGLPixelFormat - NSOpenGLPixelFormat for the NextBSD WindowServer

   Copyright (C) 2026 Joseph Maloney

   Modelled on WaylandGLPixelFormat.m.

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

#include "config.h"
#include <Foundation/NSDebug.h>
#include <string.h>

#include "nextbsd/NextBSDOpenGL.h"

#ifdef NEXTBSD_HAVE_GL

/* Implemented in NextBSDGLContext.m: load EGL and set it up on the
   server's render node, once. */
extern BOOL NextBSDGLSetUp(void);

/* Attributes followed by a value. */
static BOOL
takesValue(NSOpenGLPixelFormatAttribute attr)
{
  switch ((int)attr)
    {
    case NSOpenGLPFAAuxBuffers:
    case NSOpenGLPFAColorSize:
    case NSOpenGLPFAAlphaSize:
    case NSOpenGLPFADepthSize:
    case NSOpenGLPFAStencilSize:
    case NSOpenGLPFAAccumSize:
    case NSOpenGLPFARendererID:
    case NSOpenGLPFAScreenMask:
    case NSOpenGLPFASamples:
    case NSOpenGLPFASampleBuffers:
    case NSOpenGLPFAVirtualScreenCount:
    case 99:	/* NSOpenGLPFAOpenGLProfile, newer than libs-gui's list */
      return YES;
    default:
      return NO;
    }
}

@implementation NextBSDGLPixelFormat

- (id) initWithAttributes: (NSOpenGLPixelFormatAttribute *)attribs
{
  NSUInteger n = 0;

  self = [super init];
  if (self == nil)
    return nil;
  /* No OpenGL after all (no EGL on the render node): nil, so the app
     keeps its CPU path. */
  if (!NextBSDGLSetUp())
    {
      DESTROY(self);
      return nil;
    }
  if (attribs != NULL)
    {
      while (attribs[n] != 0)
	{
	  if (takesValue(attribs[n]) && attribs[n + 1] != 0)
	    n++;
	  n++;
	}
    }
  _attributeCount = n;
  _attributes = NSZoneMalloc(NSDefaultMallocZone(),
			     (n + 1) * sizeof(NSOpenGLPixelFormatAttribute));
  if (n > 0)
    memcpy(_attributes, attribs, n * sizeof(NSOpenGLPixelFormatAttribute));
  _attributes[n] = 0;
  return self;
}

- (void) dealloc
{
  if (_attributes != NULL)
    NSZoneFree(NSDefaultMallocZone(), _attributes);
  [super dealloc];
}

- (int) valueForAttribute: (NSOpenGLPixelFormatAttribute)attr
		  default: (int)def
{
  NSUInteger i;

  for (i = 0; i < _attributeCount; i++)
    {
      if (_attributes[i] == attr)
	{
	  if (!takesValue(attr))
	    return 1;
	  return i + 1 < _attributeCount ? (int)_attributes[i + 1] : def;
	}
      if (takesValue(_attributes[i]))
	i++;
    }
  return def;
}

- (void) getValues: (int *)vals
      forAttribute: (NSOpenGLPixelFormatAttribute)attrib
  forVirtualScreen: (int)screen
{
  if (vals != NULL)
    *vals = [self valueForAttribute: attrib default: 0];
}

- (int) numberOfVirtualScreens
{
  return 1;
}

@end

#endif /* NEXTBSD_HAVE_GL */
