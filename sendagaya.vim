function! s:setup()
  tabnew

  let bounds = {}

  " Ratios of font width and height
  let FONT_WIDTH = 1.0
  let FONT_HEIGHT = 2.0

  " Drawable region (in character)
  let bounds.width_c = winwidth(0)
  let bounds.height_c = winheight(0)

  " Drawable region (in virtual pixel)
  let bounds.width_r = bounds.width_c * FONT_WIDTH
  let bounds.height_r = bounds.height_c * FONT_HEIGHT

  " Load map data
  let map = json_decode(join(readfile('sendagaya.json'), ''))['osm']

  " Data region (in data-specific unit)
  let bounds.x1_d = str2float(map.bounds.minlon)
  let bounds.y1_d = str2float(map.bounds.minlat)
  let bounds.x2_d = str2float(map.bounds.maxlon)
  let bounds.y2_d = str2float(map.bounds.maxlat)
  let bounds.width_d = bounds.x2_d - bounds.x1_d
  let bounds.height_d = bounds.y2_d - bounds.y1_d

  " Buffer for rendering and naming
  let nram = {}
  let vram = []
  for _ in range(bounds.height_c)
    call add(vram, repeat([' '], bounds.width_c))
  endfor

  " Render named ways to vram
  let node_from_id = {}
  for node in map.node
    let node_from_id[node.id] = node
  endfor
  for way in map.way
    let tag = get(way, 'tag')
    if type(tag) != type([])
      continue
    endif
    let name_tags = filter(copy(tag), {_, v -> v.k ==# 'name'})
    if len(name_tags) == 0
      continue
    endif
    let name = name_tags[0].v
    let px_d = 0
    let py_d = 0
    for nd in way.nd
      let node = node_from_id[nd.ref]
      let nx_d = str2float(node['lon'])
      let ny_d = str2float(node['lat'])
      if px_d != 0 && py_d != 0
        let dx_d = nx_d - px_d
        let dy_d = ny_d - py_d
        let ratio = abs(dx_d) / abs(dy_d)
        if ratio <= 0.25
          let c = '|'
        elseif ratio <= 0.75
          if dx_d < 0 && dy_d < 0 || dx_d > 0 && dy_d > 0
            let c = '/'
          else
            let c = '\'
          endif
        else
          let c = '-'
        endif
        let dxp = abs(dx_d) / bounds.width_d
        let dyp = abs(dy_d) / bounds.height_d
        let tm = max([float2nr(dxp * 100), float2nr(dyp * 100)]) * 3
        for t in range(tm)
          call s:put(vram, c, nram, name, px_d + dx_d * t / tm, py_d + dy_d * t / tm, bounds)
        endfor
      endif
      let px_d = nx_d
      let py_d = ny_d
    endfor
    call s:put(vram, c, nram, name, px_d, py_d, bounds)
  endfor

  " Render named nodes to vram
  for node in map.node
    let tag = get(node, 'tag')
    if type(tag) == type([])
      let name_tags = filter(copy(tag), {_, v -> v.k ==# 'name'})
      if len(name_tags) == 0
        let name = 0
      else
        let name = name_tags[0].v
      endif
      call s:put(vram, 'o', nram, name, str2float(node['lon']), str2float(node['lat']), bounds)
    endif
  endfor

  " Render to Vim buffer
  call s:render(vram)

  " Set up stuffs for interactive elements
  let b:vram = vram
  let b:nram = nram
  let b:pchar = 0
  let b:bounds = bounds
  let b:cursor_adjusted = 0
  nnoremap <silent> K  :<C-u>call <SID>what()<CR>
  autocmd CursorMoved <buffer>  call s:what()
  autocmd BufLeave <buffer>  call s:stop_location_monitor()
  highlight vpsCurrent term=bold cterm=bold ctermfg=Black ctermbg=Cyan gui=bold guifg=Black guibg=Cyan
  syntax match vpsCurrent /@/
  call s:start_location_monitor()
endfunction

function! s:render(vram)
  let pos = getpos('.')

  % delete _
  silent put =map(copy(a:vram), {_, line -> join(line, '')})
  1 delete _

  call setpos('.', pos)
endfunction

function! s:start_location_monitor()
  let b:job = job_start('stdbuf --output=L CoreLocationCLI', {'out_cb': function('s:on_update')})
endfunction

function! s:on_update(channel, message)
  let matches = matchlist(a:message, '\v^\<\+?(\-?[0-9.]+),\+?(\-?[0-9.]+)>')
  if matches == []
    return
  endif

  let b:message = a:message
  let &l:statusline = '%{b:message}   ' . &g:statusline

  if b:pchar isnot 0
    call s:put(b:vram, b:pchar, b:nram, 0, b:px_d, b:py_d, b:bounds)
  endif

  let b:px_d = str2float(matches[2])
  let b:py_d = str2float(matches[1])
  let b:pchar = s:get(b:vram, b:px_d, b:py_d, b:bounds)
  if b:pchar isnot 0
    call s:put(b:vram, '@', b:nram, 0, b:px_d, b:py_d, b:bounds)
  endif

  call s:render(b:vram)

  if !b:cursor_adjusted && b:pchar isnot 0
    call search('@', 'w')
    setlocal cursorline cursorcolumn
    let b:cursor_adjusted = 1
  endif
endfunction

function! s:stop_location_monitor()
  call job_stop(b:job)
endfunction

function! s:what()
  let x = col('.') - 1
  let y = line('.') - 1
  let names = keys(get(b:nram, x . ',' . y, {}))
  if len(names) == 0
    echo '?'
  else
    echo names
  endif
endfunction

function! s:get(vram, x_d, y_d, bounds)
  let x_r = s:x_r_from_x_d(a:x_d, a:bounds)
  let y_r = s:y_r_from_y_d(a:y_d, a:bounds)
  let x_c = s:x_c_from_x_r(x_r, a:bounds)
  let y_c = s:y_c_from_y_r(y_r, a:bounds)
  if 0 <= x_c && x_c < a:bounds.width_c && 0 <= y_c && y_c < a:bounds.height_c
    let y_c = a:bounds.height_c - y_c - 1
    return a:vram[y_c][x_c]
  else
    return 0
  endif
endfunction

function! s:put(vram, char, nram, name, x_d, y_d, bounds)
  let x_r = s:x_r_from_x_d(a:x_d, a:bounds)
  let y_r = s:y_r_from_y_d(a:y_d, a:bounds)
  let x_c = s:x_c_from_x_r(x_r, a:bounds)
  let y_c = s:y_c_from_y_r(y_r, a:bounds)
  if 0 <= x_c && x_c < a:bounds.width_c && 0 <= y_c && y_c < a:bounds.height_c
    let y_c = a:bounds.height_c - y_c - 1
    let a:vram[y_c][x_c] = a:char

    if a:name isnot 0
      let nram_index = x_c . ',' . y_c
      let names = get(a:nram, nram_index, {})
      let names[a:name] = 1
      let a:nram[nram_index] = names
    endif
  endif
endfunction

function! s:x_r_from_x_d(x_d, bounds)
  let fit_to_width = a:bounds.width_r / a:bounds.height_r >= a:bounds.width_d / a:bounds.height_d
  if fit_to_width
    return (a:x_d - a:bounds.x1_d) * a:bounds.width_r / a:bounds.width_d
  else
    let padding = a:bounds.width_d * a:bounds.height_r / a:bounds.height_d - a:bounds.width_r
    return (a:x_d - a:bounds.x1_d) * a:bounds.height_r / a:bounds.height_d - padding / 2
  endif
endfunction

function! s:y_r_from_y_d(y_d, bounds)
  let fit_to_width = a:bounds.width_r / a:bounds.height_r >= a:bounds.width_d / a:bounds.height_d
  if fit_to_width
    let padding = a:bounds.height_d * a:bounds.width_r / a:bounds.width_d - a:bounds.height_r
    return (a:y_d - a:bounds.y1_d) * a:bounds.width_r / a:bounds.width_d - padding / 2
  else
    return (a:y_d - a:bounds.y1_d) * a:bounds.height_r / a:bounds.height_d
  endif
endfunction

function! s:x_c_from_x_r(x_r, bounds)
  return float2nr(a:x_r * a:bounds.width_c / a:bounds.width_r)
endfunction

function! s:y_c_from_y_r(y_r, bounds)
  return float2nr(a:y_r * a:bounds.height_c / a:bounds.height_r)
endfunction

call s:setup()
