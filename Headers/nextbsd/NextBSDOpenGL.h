/*
   NextBSDOpenGL.h

   NSOpenGLContext and NSOpenGLPixelFormat for the NextBSD WindowServer:
   OpenGL drawn on the GPU into GPU buffers (dmabufs) that WindowServer
   composites without a copy.

   Copyright (C) 2026 Joseph Maloney

   Modelled on the Wayland backend's WaylandOpenGL.h.

   This file is part of the GNUstep Backend.

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
 * OpenGL on WindowServers with GPU buffers (WS_SERVER_DMABUF, the
 * gles2 renderer). A context draws with EGL on the GPU WindowServer
 * names (ws_dmabuf_formats(): its render node, and the formats and
 * modifiers it composites fastest, Broadcom's tiled UIF on a Pi 5),
 * into a GBM window surface the size of its view. libEGL and libgbm are
 * loaded when the first pixel format is made, so apps that don't use
 * OpenGL don't load Mesa, and a system without it just has no OpenGL.
 * The context is desktop OpenGL (a compatibility profile, as
 * NSOpenGLView code expects), or OpenGL ES 2 where the driver has no
 * desktop OpenGL; NB_GL_API=gles in the environment asks for OpenGL ES.
 *
 * -flushBuffer shows the frame in one of two ways:
 *
 *  - The view covers the whole window (a borderless window whose
 *    content view, or a subview filling it, is the GL view: a full-screen
 *    game, InnerSpace's desktop). The frame's buffer becomes the window's
 *    buffer: attached and committed, with no copy at all. While the
 *    context presents the window this way, the window's cairo surface
 *    stops committing (and gives its buffers back), so the two never
 *    fight over the window; it takes over again, redrawing the whole
 *    window, when the context stops (-clearDrawable, a smaller view, the
 *    context going away).
 *
 *  - Otherwise (a GL view inside a window with other views, a titled
 *    window), the frame is read back with glReadPixels into the view's
 *    part of the window's cairo back store, and flushed with the rest of
 *    the window. That is correct but costs a copy through the CPU.
 *
 * Without GPU buffers (an older WindowServer, the pixman renderer), or
 * without EGL on the render node, the backend has no OpenGL: -[NextBSDServer
 * glContextClass] answers nil, so NSOpenGLPixelFormat and NSOpenGLContext
 * allocate nil and apps keep their CPU paths.
 *
 * HiDPI: as on macOS, the drawable is the view's size in points, and
 * WindowServer scales it to the screen, unless the view answers YES to
 * -wantsBestResolutionOpenGLSurface (an NSView method on macOS, which a
 * view can implement here): then it has a pixel per backing pixel
 * (-[NSWindow backingScaleFactor] times its size in points).
 *
 * Pacing: a frame is shown at the next vertical blank after
 * -flushBuffer (WindowServer's WS_EVENT_FRAME_DONE says when). An app
 * that wants to draw one frame per refresh, and nothing while its window
 * isn't being redrawn, asks the context to tell it:
 *
 *   SEL sel = @selector(setFrameCallbackTarget:selector:);
 *   if ([ctx respondsToSelector: sel])
 *     [ctx setFrameCallbackTarget: self selector: @selector(frameDone:)];
 *
 * after which -frameDone: (with the context as its argument) runs from
 * the run loop once the frame of each -flushBuffer is on screen; draw
 * and flush the next frame there. NSOpenGLCPSwapInterval 1 makes
 * -flushBuffer itself wait until the previous frame is on screen.
 * Either way, -flushBuffer waits for WindowServer to give a buffer back
 * when every buffer is in use.
 */

#ifndef _NextBSDOpenGL_h_INCLUDE
#define _NextBSDOpenGL_h_INCLUDE

#include <Foundation/NSGeometry.h>
#include <AppKit/NSOpenGL.h>
#include <WindowServer/WSClient.h>

/* OpenGL needs WindowServer's GPU buffer API, and the EGL and GBM
   headers to build (the libraries are loaded at run time). */
#if defined(WS_SERVER_DMABUF) && defined(__has_include)
#  if __has_include(<EGL/egl.h>) && __has_include(<gbm.h>)
#    define NEXTBSD_HAVE_GL 1
#  endif
#endif

#ifdef NEXTBSD_HAVE_GL

@class NSView;
struct gbm_surface;
struct nextbsd_gl_buffer;

@interface NextBSDGLPixelFormat : NSOpenGLPixelFormat
{
  NSOpenGLPixelFormatAttribute *_attributes;
  NSUInteger _attributeCount;
}
/* The value of attribute attr, or def if it isn't given; a flag
   (NSOpenGLPFADoubleBuffer...) is 1 when given. */
- (int) valueForAttribute: (NSOpenGLPixelFormatAttribute)attr
		  default: (int)def;
@end

@interface NextBSDGLContext : NSOpenGLContext
{
  NextBSDGLPixelFormat	*_format;
  NSOpenGLContext	*_share;
  NSView		*_view;
  void			*_eglContext;	/* EGLContext */
  void			*_eglConfig;	/* EGLConfig */
  uint32_t		 _gbmFormat;	/* the config's GBM_FORMAT_* */
  /* the drawable */
  int			 _window;	/* window number, 0 none */
  struct gbm_surface	*_gbmSurface;
  void			*_eglSurface;	/* EGLSurface */
  int			 _width;	/* pixels */
  int			 _height;
  int			 _scale;	/* pixels per point (buffers' scale) */
  BOOL			 _exclusive;	/* the frames are the window's buffers */
  BOOL			 _owner;	/* presenting the window (w->glOwner) */
  NSRect		 _viewRect;	/* in the window, top-left points */
  struct nextbsd_gl_buffer *_buffers;	/* the surface's buffers WindowServer
					   knows (exclusive) */
  int			 _bufferCount;
  /* pacing */
  BOOL			 _framePending;	/* flushed, not yet on screen */
  BOOL			 _callbackDue;	/* tell the target when it is */
  id			 _frameTarget;	/* not retained */
  SEL			 _frameSelector;
  long			 _swapInterval;
  long			 _opacity;	/* NSOpenGLCPSurfaceOpacity */
  unsigned char		*_readback;	/* composited frames */
  size_t		 _readbackSize;
}

/* Whether the backend can make OpenGL contexts: the server has GPU
   buffers and the client library their API. EGL itself is checked when
   the first pixel format is made. */
+ (BOOL) isAvailable;

/* Events for the context's window (NextBSDServer+Events.m). */
+ (BOOL) bufferReleased: (uint32_t)bufferId;
+ (void) frameDoneForWindow: (int)win;
+ (void) windowWillClose: (int)win;

/* See "Pacing" above. The target isn't retained; give nil before it
   goes away. */
- (void) setFrameCallbackTarget: (id)target selector: (SEL)selector;
/* YES between -flushBuffer and the frame being on screen. */
- (BOOL) isFramePending;
/* The drawable's size in pixels (the view's in points, or in backing
   pixels with -wantsBestResolutionOpenGLSurface), zero without one. */
- (NSSize) drawableSize;
@end

#endif /* NEXTBSD_HAVE_GL */

#endif /* _NextBSDOpenGL_h_INCLUDE */
