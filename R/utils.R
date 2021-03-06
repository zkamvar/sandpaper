# Null operator
`%||%` <- function(a, b) if (is.null(a)) b else a

`%nin%` <- Negate("%in%")

as_html <- function(i) fs::path_ext_set(fs::path_file(i), "html")

# Parse a markdown title to html
#
# Note that commonmark wraps the content in <p> tags, so the substring gets rid
# of those:
# <p>Title</p>\n
parse_title <- function(title) {
  title <- commonmark::markdown_html(title)
  substring(title, 4, nchar(title) - 5)
}

UTC_timestamp <- function(x) format(x, "%F %T %z", tz = "UTC")

# Functions for backwards compatibility for R < 3.5
isFALSE <- function(x) is.logical(x) && length(x) == 1L && !is.na(x) && !x
isTRUE  <- function(x) is.logical(x) && length(x) == 1L && !is.na(x) && x

# If the git user is not set, we set a temporary one, note that this is paired
# with reset_git_user()
check_git_user <- function(path) {
  if (!gert::user_is_configured(path)) {
    gert::git_config_set("user.name", "carpenter", repo = path)
    gert::git_config_set("user.email", "team@carpentries.org", repo = path)
  }
}

# It's clear that we cannot rely on folks having the correct libgit2 version,
# so the way we enforce the main branch is to do it after we make the initial
# commit like so:
#
#  1. create a new branch called "main"
#  2. change "master" to "main" in .git/HEAD (txt file)
#  3. delete "master" branch 
# 
# If the user HAS set a default branch, we will use that one.
enforce_main_branch <- function(path) {
  current <- gert::git_branch(path)
  default <- get_default_branch()
  if (current != "master") {
    # the user set up their init.defaultBranch correctly
    return(path)
  }
  # Create and move to main branch
  gert::git_branch_create(default, repo = path)
  # modify .git/HEAD file
  HFILE <- file.path(path, ".git", "HEAD")
  HEAD <- readLines(HFILE, encoding = "UTF-8")
  writeLines(sub("master", default, HEAD), HFILE)
  # remove master
  gert::git_branch_delete("master", repo = path)
}

get_default_branch <- function() {
  cfg <- gert::git_config_global()
  default <- cfg$value[cfg$name == "init.defaultbranch"]
  invalid <- length(default) == 0 || default == "master"
  if (invalid) "main" else default
}

# This checks if we have set a temporary git user and then unsets it. It will 
# supriously unset a user if they happened to have 
# "carpenter <team@carpentries.org>" as their email.
reset_git_user <- function(path) {
  cfg <- gert::git_config(path)
  it_me <- cfg$value[cfg$name == "user.name"] == "carpenter" &&
    cfg$value[cfg$name == "user.email"] == "team@carpentries.org"
  if (gert::user_is_configured(path) && it_me) {
    gert::git_config_set("user.name", NULL, repo = path)
    gert::git_config_set("user.email", NULL, repo = path)
  }
}

create_lesson_readme <- function(name, path) {

  writeLines(glue::glue("# {name}
      
      This is the lesson repository for {name}
  "), con = fs::path(path, "README.md"))

}

create_site_readme <- function(path) {
  readme <- fs::path(path_site(path), "README.md")
  if (!fs::file_exists(readme)) {
    fs::file_create(readme)
  }
  writeLines(glue::glue("
  This directory contains rendered lesson materials. Please do not edit files
  here.  
  "), con = readme)
}

create_description <- function(path) {
  yaml <- yaml::read_yaml(path_config(path))
  the_author <- paste(gert::git_signature_default(path), "[aut, cre]")
  the_author <- utils::as.person(the_author)
  desc <- desc::description$new("!new")
  desc$del(c("BugReports", "LazyData"))
  desc$set_authors(the_author)
  desc$set(
    Package     = "lesson",
    Title       = yaml$title,
    Description = "Lesson Template (not a real package).",
    License     = yaml$license,
    Encoding    = "UTF-8"
  )
  desc$write(fs::path(path_site(path), "DESCRIPTION"))
}

which_carpentry <- function(carpentry) {
  switch(carpentry,
    lc = "Library Carpentry",
    dc = "Data Carpentry",
    swc = "Software Carpentry",
    cp = "The Carpentries",
  )
}

create_pkgdown_yaml <- function(path) {
  # The user does not interact with this and {{mustache}} is logic-less, so we
  # can be super-verbose here and create any logic we need on the R-side.
  usr <- yaml::read_yaml(path_config(path))
  yaml <- get_yaml_text(template_pkgdown())
  yaml <- whisker::whisker.render(yaml, 
    data = list(
      # Basic information
      version = utils::packageVersion("sandpaper"),
      config  = path_config(path),
      title   = usr$title,
      time    = UTC_timestamp(Sys.time()),
      source  = usr$source,
      branch  = usr$branch,
      contact = usr$contact,
      # What carpentry are we dealing with?
      carpentry_name = which_carpentry(usr$carpentry),
      carpentry      = usr$carpentry,
      cp             = usr$carpentry == 'cp',
      lc             = usr$carpentry == 'lc',
      dc             = usr$carpentry == 'dc',
      swc            = usr$carpentry == 'swc',
      # Should we display a lifecycle banner?
      life_cycle = if (usr$life_cycle == "stable")    "~"  else usr$life_cycle,
      pre_alpha  = if (usr$life_cycle == "pre-alpha") TRUE else "~",
      alpha      = if (usr$life_cycle == "alpha")     TRUE else "~",
      beta       = if (usr$life_cycle == "beta")      TRUE else "~",
      NULL     
    )
  )
  structure(yaml::yaml.load(yaml), header = get_information_header(yaml))
}

update_site_timestamp <- function(path) {
  yaml <- get_path_site_yaml(path) 
  yaml$template$params$time <- Sys.time()
  write_pkgdown_yaml(yaml, path)
}

get_navbar_info <- function(i) {
  txt <- yaml::yaml.load(politely_get_yaml(i))$title
  list(
    pagetitle = txt,
    text  = txt,
    href  = as_html(i)
  )
}

site_menu <- function(yaml, files = NULL, position = 3L) {
  if (is.null(files) || length(files) == 0L) return(yaml)
  res <- lapply(files, get_navbar_info)
  yaml$navbar$left[[position]]$menu <- unname(res)
  yaml
}


# Take a list of episodes and update the yaml configuration. 
# TODO: This implementation needs to change!!!
update_site_menu <- function(path, 
  episodes = NULL, learners = NULL, instructors = NULL, profiles = NULL) {
  yaml <- get_path_site_yaml(path) 
  # NOTE: change tests/testthat/test-set_dropdown.R
  yaml <- site_menu(yaml, episodes,    2L)
  yaml <- site_menu(yaml, learners,    3L)
  yaml <- site_menu(yaml, instructors, 4L)
  yaml <- site_menu(yaml, profiles,    5L)
  write_pkgdown_yaml(yaml, path)
}

copy_assets <- function(src, dst) {
  # Do not take markdown files.
  if (fs::path_ext(src) == "md") return(invisible(NULL))

  # FIXME: modify this to allow for non-flat file structure
  dst <- fs::path(dst, fs::path_file(src))

  # Copy either directories or files.
  if (fs::is_dir(src) && fs::path_file(src) != ".git") {
    fs::dir_copy(src, dst, overwrite = TRUE)
  } else if (fs::is_file(src) && fs::path_file(src) != ".git") {
    fs::file_copy(src, dst, overwrite = TRUE)
  } else if (fs::path_file(src) == ".git") {
    # skipping git
  } else {
    stop(paste(src, "does not exist"), call. = FALSE)
  }
  return(invisible(NULL))
}

get_figs <- function(path, slug) {
  fs::path_abs(
    fs::dir_ls(
      path = fs::path(path_built(path), "fig"),
      regexp = paste0(slug, "-rendered-"),
      fixed = TRUE
    )
  )
}

check_order <- function(order, what) {
  if (is.null(order)) {
    stop(paste(what, "must have an order"), call. = FALSE)
  }
}


#nocov start
# Make it easy to contribute to our gitignore template, but also avoid having
# to reload this thing every time we need it 
gitignore_items <- function() {
  ours <- readLines(template_gitignore(), encoding = "UTF-8")
  ours[!grepl("^([#].+?|)$", trimws(ours))]
}

.onLoad <- function(libname, pkgname) {
  ns <- asNamespace(pkgname)
  delayedAssign("GITIGNORED", gitignore_items(), eval.env = ns, assign.env = ns)
}
#nocov end

