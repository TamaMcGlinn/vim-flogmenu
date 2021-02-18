
fu! flogmenu#git(command) abort
  let l:cmd = "git " . a:command
  let l:out = system(l:cmd)
  return substitute(out, '\c\C\n$', '', '')
endfunction

fu! flogmenu#git_then_update(command) abort
  let git_output = flogmenu#git(a:command)
  call flog#populate_graph_buffer()
  return l:git_output
endfunction

" Gets the references attached to the commit on the selected line
fu! flogmenu#get_refs(commit)
  if type(a:commit) != v:t_dict
    throw g:flogmenu_commit_parse_error
  endif

  " TODO replace until next marker with this after flog PR#48 is approved
  " let [l:local_branches, l:remote_branches, l:tags, l:special] = flog#parse_ref_name_list(a:commit)
  let l:local_branches = []
  let l:remote_branches = []
  let l:special = []
  let l:tags = []
  if !empty(a:commit.ref_name_list)
    let l:refs = a:commit.ref_name_list
    let l:original_refs = split(a:commit.ref_names_unwrapped, ' \ze-> \|, \|\zetag: ')
    let l:i = 0
    while l:i < len(l:refs)
      let l:ref = l:refs[l:i]
      if l:ref =~# 'HEAD$\|^refs/'
        call add(l:special, l:ref)
      elseif l:original_refs[l:i] =~# '^tag: '
        call add(l:tags, l:ref)
      elseif flog#is_remote_ref(l:ref)
        call add(l:remote_branches, l:ref)
      else
        call add(l:local_branches, l:ref)
      endif
      let l:i += 1
    endwhile
  endif
  " end TODO replacement

  let l:current_branch = flogmenu#git('rev-parse --abbrev-ref HEAD')
  let l:other_local_branches = filter(l:local_branches, 'l:current_branch != v:val')
  return {
     \ 'current_branch': l:current_branch,
     \ 'local_branches': l:local_branches,
     \ 'other_local_branches': l:other_local_branches,
     \ 'remote_branches': l:remote_branches,
     \ 'tags': l:tags,
     \ 'special': l:special
     \ }
endfunction

" this should be done once per interaction,
" so the result needs to be stored for submenus to
" access. The _fromcache functions are thus meant
" for in menu options, while the version without
" will call this first to set the global g:flogmenu_selection_info
fu! flogmenu#set_selection_info() abort
  let l:commit = flog#get_commit_at_line()
  let g:flogmenu_selection_info = flogmenu#get_refs(l:commit)
  let g:flogmenu_selection_info['selected_commit'] = l:commit
  let l:current_commit = flogmenu#git('rev-parse HEAD')
  let l:full_commit_hash = fugitive#RevParse(l:commit.short_commit_hash)
  let g:flogmenu_selection_info['selected_commit_hash'] = l:full_commit_hash
  let g:flogmenu_selection_info['different_commit'] = l:current_commit != l:full_commit_hash
endfunction

fu! flogmenu#create_branch_menu() abort
  call flogmenu#set_selection_info()
  call flogmenu#create_branch_menu_fromcache()
endfunction

fu! flogmenu#create_given_branch_fromcache(branchname) abort
  call inputsave()
  let l:wants_to_switch = input("Switch to the branch? (y)es / (n)o ")
  call inputrestore()

  if l:wants_to_switch == 'y'
    call flogmenu#create_given_branch_and_switch_fromcache(a:branchname)
  else
    call flogmenu#git_then_update('branch ' . a:branchname . ' ' . g:flogmenu_selection_info.selected_commit_hash)
  endif
endfunction

fu! flogmenu#create_given_branch_and_switch_fromcache(branchname) abort
  let l:branch = substitute(a:branchname, '^[^/]*/', '', '')
  call flogmenu#git_then_update('checkout -b ' . l:branch . ' ' . g:flogmenu_selection_info.selected_commit_hash)
endfunction

fu! flogmenu#create_input_branch_fromcache() abort
  call inputsave()
  let l:branchname = input("Branch: ")
  call inputrestore()
  call create_given_branch_fromcache(l:branchname)
endfunction

fu! flogmenu#create_branch_menu_fromcache() abort
  let l:branch_menu = []
  let l:unmatched_remote_branches = filter(g:flogmenu_selection_info.remote_branches,
    "index(g:flogmenu_selection_info.local_branches, substitute(v:val, '^[^/]*/', '', '') < 0")
  for l:unmatched_branch in l:unmatched_remote_branches
    call add(l:branch_menu, [l:unmatched_branch,
      'call flogmenu#create_given_branch_fromcache("' . l:unmatched_branch . '"')']
  endfor
  call add(l:branch_menu, ['-custom', 'call flogmenu#create_input_branch_fromcache()'])
  call quickui#context#open(l:branch_menu, g:flogmenu_opts)
endfunction

fu! flogmenu#create_branch_menu() abort
  call flogmenu#set_selection_info()
  call flogmenu#create_branch_menu_fromcache()
endfunction

" Returns 1 if the user chose to abort, otherwise 0
fu! flogmenu#handle_unstaged_changes() abort
  call flogmenu#git('update-index --refresh')
  call flogmenu#git('diff-index --quiet HEAD --')
  let l:has_unstaged_changes = v:shell_error != 0
  if l:has_unstaged_changes
    call inputsave()
    let l:unstaged_info = flogmenu#git('diff --stat')
    let l:choice = input("Unstaged changes: \n" . l:unstaged_info . "\n> (a)bort / (d)iscard / (s)tash ")
    call inputrestore()
    if l:choice == 'd'
      call system('git checkout -- .') " TODO this doesn't work - need to throw away unstaged changes
    elseif l:choice == 's'
      call flogmenu#git('stash')
    else " All invalid input also means abort
      return 1
    endif
  endif
  return 0
endfunction

fu! flogmenu#checkout() abort
  call flogmenu#set_selection_info()
  call flogmenu#checkout_fromcache()
endfunction

fu! flogmenu#checkout_fromcache() abort
  " Are we moving to a different commit? If so, check the git status is clean
  if g:flogmenu_selection_info.different_commit
    if flogmenu#handle_unstaged_changes() == 1
      return
    endif
  endif
  let l:branch_menu = []
  " If there are other local branches, these are the most likely choices
  " so they come first
  for l:local_branch in g:flogmenu_selection_info.other_local_branches
    call add(l:branch_menu, [l:local_branch, 'call flogmenu#git_then_update("checkout ' . l:local_branch . '")'])
  endfor
  " Next, offer the choices to create branches for unmatched remote branches
  let l:unmatched_remote_branches = filter(g:flogmenu_selection_info.remote_branches,
        \ "index(g:flogmenu_selection_info.local_branches, substitute(v:val, '^[^/]*/', '', '')) < 0")
  for l:unmatched_branch in l:unmatched_remote_branches
    call add(l:branch_menu, [l:unmatched_branch,
          \ 'call flogmenu#create_given_branch_and_switch_fromcache("' . l:unmatched_branch . '")'])
  endfor
  " Finally, choices to make new branch or none at all
  call add(l:branch_menu, ['-create branch', 'call flogmenu#create_branch_menu_fromcache()'])
  call add(l:branch_menu, ['-detached HEAD', 'call flogmenu#git_then_update("checkout " . g:flogmenu_selection_info.selected_commit_hash)'])
  call quickui#context#open(l:branch_menu, g:flogmenu_opts)
  " TODO generically, using function to replace quickui#context#open; If only one choice, do it immediately
    " call flogmenu#git('checkout ' . g:flogmenu_selection_info.other_local_branches[0])
    " call flog#populate_graph_buffer()
endfunction

fu! flogmenu#rebase_fromcache() abort
  let l:target = g:flogmenu_selection_info.selected_commit_hash
  execute 'Git rebase ' . l:target . ' --interactive --autosquash'
endfunction

fu! flogmenu#rebase() abort
  call flogmenu#set_selection_info()
  call flogmenu#rebase_fromcache()
endfunction

fu! flogmenu#excluding_rebase_fromcache() abort
  let l:target = g:flogmenu_selection_info.selected_commit_hash
  echom '\nTo conclude, open the context menu again on the commit you want to exclude.\n' .
        'To cancel, exclude the final commit on your branch.'
  let g:flogmenu_takeover_context_menu = {'type':    'rebase_exclude',
                                        \ 'target':  l:target }
endfunction

fu! flogmenu#excluding_rebase() abort
  call flogmenu#set_selection_info()
  call flogmenu#excluding_rebase_fromcache()
endfunction

fu! flogmenu#rebase_exclude_fromcache() abort
  let l:target = g:flogmenu_takeover_context_menu.target
  let l:exclude = g:flogmenu_selection_info.selected_commit_hash
  execute "Git rebase --interactive --autosquash --onto " . l:target . ' ' . l:exclude
endfunction

fu! flogmenu#reset_hard() abort
  call flog#run_command("Git reset --hard %h", 0, 1)
endfunction

fu! flogmenu#reset_mixed() abort
  call flog#run_command("Git reset --mixed %h", 0, 1)
endfunction

fu! flogmenu#cherrypick() abort
  call flog#run_command("Git cherry-pick %h", 0, 1)
endfunction

fu! flogmenu#merge_fromcache() abort
  " check the git status is clean
  if flogmenu#handle_unstaged_changes() == 1
    return
  endif
  let l:merge_choices = []
  for l:local_branch in g:flogmenu_selection_info.other_local_branches + g:flogmenu_selection_info.unmatched_remote_branches
    call add(l:merge_choices, [l:local_branch, 'call flog#run_command("Git merge ' . l:local_branch . '", 0, 1)'])
  endfor
  if len(l:merge_choices) == 1
    execute l:merge_choices[0][1]
  else
    call quickui#context#open(l:merge_choices, g:flogmenu_opts)
  endif
endfunction

fu! flogmenu#delete_branch_fromcache() abort
endfunction

fu! flogmenu#open_main_contextmenu() abort
  call flogmenu#set_selection_info()
  if type(g:flogmenu_takeover_context_menu) ==# v:t_dict
    if g:flogmenu_takeover_context_menu.type ==# 'rebase_exclude'
      call flogmenu#rebase_exclude_fromcache()
    endif
    let g:flogmenu_takeover_context_menu = v:null
  else
    " Note; all menu items should refer to _fromcache variants,
    " whereas all direct bindings refer to the regular variant
    " this ensures that set_selection_info is called once, even if
    " the user traverses several menu's
    let l:flogmenu_main_menu = [
                             \ ["&Checkout", 'call flogmenu#checkout_fromcache()'],
                             \ ["&Merge", 'call flogmenu#merge_fromcache()'],
                             \ ["Reset --&mixed", 'call flogmenu#reset_mixed()'],
                             \ ["Reset --&hard", 'call flogmenu#reset_hard()'],
                             \ ["Cherry&pick", 'call flogmenu#cherrypick()'],
                             \ ["Create &branch", 'call flogmenu#create_branch_menu_fromcache()'],
                             \ ["&Rebase", 'call flogmenu#rebase_fromcache()'],
                             \ ["Rebase e&xcluding", 'call flogmenu#excluding_rebase_fromcache()'],
                             \ ]
    call quickui#context#open(l:flogmenu_main_menu, g:flogmenu_opts)
  endif
endfunction

fu! flogmenu#open_main_menu() abort
  call quickui#menu#switch('flogmenu')
  call quickui#menu#reset()
  " install a 'File' menu, use [text, command] to represent an item.
  call quickui#menu#install('&Repo', [
              \ [ "&Status", 'normal! :G' ],
              \ [ "&Log", 'execute :Flog -all' ],
              \ [ "&Fetch", 'execute :Git fetch' ]
              \ ])
  call quickui#menu#open()
endfunction
