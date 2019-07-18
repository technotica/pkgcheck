#!/bin/zsh

# CheckInstallationScripts.zsh

# this script will look into pkg files and warn if any of the installation scripts
# use one of the following shebangs:
# 
# /bin/bash
# /usr/bin/python
# /usr/bin/perl
# /usr/bin/ruby
#
# also checks for signatures and notarization


function mkcleandir() { # $1: dirpath
    local dirpath=${1:?"no dir path"}
    if [[ -d $dirpath ]]; then
        if ! rm -rf "${dirpath:?no dir path}"; then
            return 1
        fi
    fi
    if ! mkdir -p "$dirpath"; then
        return 2
    fi
}

function pkgType() { #1: path to pkg
    local pkgpath=${1:?"no pkg path"}
    
    # if extension is not pkg or mpkg: no pkg installer
    if [[ $pkgpath != *.(pkg|mpkg) ]]; then
        echo "no_pkg"
        return 1
    fi
    
    # mpkg extension : mpkg bundle type
    if [[ $pkgpath == *.mpkg ]]; then
        echo "bundle_mpkg"
        return 0
    fi
    
    # if it is a directory with a pkg extension it is probably a bundle pkg
    if [[ -d $pkgpath ]]; then
        echo "bundle_pkg"
        return 0
    else
        # flat pkg, try to extract Distribution XML
        distributionxml=$(tar -xOf "$pkgpath" Distribution 2>/dev/null )
        if [[ $? == 0 ]]; then
            # distribution pkg, try to extract identifier
            identifier=$(xmllint --xpath "string(//installer-gui-script/product/@id)" - <<<${distributionxml})
            if [[ $? != 0 ]]; then
                # no identifier, normal distribution pkg
                echo "flat_distribution"
                return 0
            else
                echo "flat_distribution_productarchive"
                return 0
            fi
        else
            # no distribution xml, likely a component pkg
            echo "flat_component"
            return 0
        fi
    fi
}

function getPkgSignature() { # $1: pkgpath
    local pkgpath=${1:?"no pkg path"}
    signature=$(pkgutil --check-signature "$pkgpath" | fgrep '1. ' | cut -c 8- )
    if [[ -z $signature ]]; then
        signature="None"
    fi
    echo "$signature"
    return
}

function getComponentPkgScriptDir() { # $1: pkgpath
    local pkgpath=${1:?"no pkg path"}
    
    local pkgfullname=$(basename $pkgpath)
    local pkgname=${pkgfullname%.*} # remove extension
    
    local extractiondir="$scratchdir/$pkgname"
    if ! mkcleandir $extractiondir; then
        #echo "couldn't clean $extractiondir"
        return 1
    fi
    
    # does the pkg _have_ a Scripts archive
    if tar -tf "$pkgpath" Scripts &>/dev/null; then
        # extract the Scripts archive to scratch
        if ! tar -x -C "$extractiondir" -f "$pkgpath" Scripts; then
            #echo "error extracting Scripts Archive from $pkgpath"
            return 2
        fi
    
        # extract the resources from the Scripts archive
        if ! tar -x -C "$extractiondir" -f "$extractiondir/Scripts"; then
            #echo "error extracting Scripts from $extractiondir/Scripts"
            return 3
        fi
    
        # remove the ScriptsArchive
        rm "$extractiondir/Scripts"
    fi
    
    # return the dir with the extracted scripts
    echo "$extractiondir"
    
    return
}

function getDistributionPkgScriptDirs() { # $1: pkgpath
    local pkgpath=${1:?"no pkg path"}
    
    local pkgpath=${1:?"no pkg path"}
    
    local pkgfullname=$(basename $pkgpath)
    local pkgname=${pkgfullname%.*} # remove extension
    
    local pkgdir="$scratchdir/$pkgname"
    
    scriptdirs=( )
    
    if ! mkcleandir $pkgdir; then
        #echo "couldn't clean $pkgdir"
        return 1
    fi
    
    # does the pkg _have_ Scripts archives?
    if components=( $(tar -tf "$pkgpath" '*.pkg$' 2>/dev/null) ); then
        for c in $components ; do
            # get the components's name
            local cname=${c%.*} # remove extension
            
            # create a subdir in extractiondir
            local extractiondir="$pkgdir/$cname"
            if ! mkcleandir $extractiondir; then
                #echo "couldn't clean $extractiondir"
                return 1
            fi
            
            # does the pkg _have_ a Scripts archive
            if tar -tf "$pkgpath" "$c/Scripts" &>/dev/null; then
                # extract the Scripts archive to scratch
                if ! tar -x -C "$extractiondir" -f "$pkgpath" "$c/Scripts"; then
                    #echo "error extracting Scripts Archive from $pkgpath"
                    return 2
                fi
    
                # extract the resources from the Scripts archive
                if ! tar -x -C "$extractiondir" -f "$extractiondir/$c/Scripts"; then
                    #echo "error extracting Scripts from $extractiondir/$c/Scripts"
                    return 3
                fi
    
                # remove the ScriptsArchive
                rm -rf "$extractiondir/$c"
            fi
    
            # return the dir with the extracted scripts
            scriptdirs+="$extractiondir"
        done
    fi
    
    return
}


function getScriptDirs() { #$1: pkgpath, $2: pkgType
    local pkgpath=${1:?"no pkg path"}
    local pkgtype=${2:?"no pkg type"}
    
    case $pkgtype in
        bundle_mpkg)
            scriptdirs=( $pkgpath/Contents/Packages/*.pkg/Contents/Resources )
            ;;
        bundle_pkg)
            scriptdirs=( $pkgpath/Contents/Resources )
            ;;
        flat_component)
            scriptdirs=( "$(getComponentPkgScriptDir $pkgpath)" )
            ;;
        flat_distribution*)
            getDistributionPkgScriptDirs $pkgpath
            ;;
        *)
            :
            ;;
    esac
    return
}

function getInfoPlistValueForKey() { # $1: pkgpath $2: key
    local pkgpath=${1:?"no pkg path"}
    local key=${2:?"no key"}
    
    infoplist="$pkgpath/Contents/Info.plist"
    if [[ -r "$infoplist" ]]; then
        /usr/libexec/PlistBuddy -c "print $key" "$infoplist"
    fi
    return
}

function checkFilesInDir() { # $1: dirpath $2: level
    local dirpath=${1:?"no directory path"}
    
    local level=${2:-0}
    if [[ level -gt 0 ]]; then
        indent="    "
    else
        indent=""
    fi
    
    IFS=$'\n'
    scriptfiles=( $(find "$dirpath" -type f ) )
    scripts_count=${#scriptfiles}
    
    echo "${indent}Contains $scripts_count resource files"
    
    for f in "${scriptfiles[@]}"; do
        if [[ -e "$f" ]]; then
            relpath="${f#"$dirpath/"}"
            
            file_description="$(file -b "$f")"
            #echo "$indent$file_description"
            if [[ "$file_description" == *"script text executable"* ]]; then
                shebang=$(head -n 1 "$f" | tr -d $'\n')
                lastelement=${shebang##*/}
                if [[ $shebang == "#!/bin/bash" || \
                      $shebang == "#!/usr/bin/python" || \
                      $shebang == "#!/usr/bin/ruby" || \
                      $shebang == "#!/usr/bin/perl" ]]; then
                    echo "$indent$fg[yellow]$relpath has shebang $shebang$reset_color"
                fi
            fi
        fi
    done
}

function checkBundlePKG() { # $1: pkgpath $2: level
    local pkgpath=${1:?"no pkg path"}
    local pkgfullname=$(basename $pkgpath)
    local pkgname=${pkgfullname%.*} # remove extension
    
    local level=${2:-0}
    if [[ level -gt 0 ]]; then
        indent="    "
        echo $indent$bold_color$pkgname$reset_color
        echo $indent$pkgpath
    else
        indent=""
    fi
    
    echo $indent"Type:           PKG Bundle"    
    
    # get version and identifier
    
    pkgidentifier=$(getInfoPlistValueForKey "$pkgpath" "CFBundleIdentifier")
    if [[ -n $pkgidentifier ]]; then
        echo $indent"Identifier:     $pkgidentifier" 
    fi
    
    pkgversion=$(getInfoPlistValueForKey "$pkgpath" "CFBundleShortVersionString")
    if [[ -n $pkgversion ]]; then
        echo $indent"Version:        $pkgversion" 
    fi
    
    # check files resources folder
    resourcesfolder="$pkgpath/Contents/Resources"
    if [[ -d $resourcesfolder ]]; then
        checkFilesInDir "$resourcesfolder" "$level"
    fi
    
    echo
}

function checkBundleMPKG() { # $1: pkgpath
    local pkgpath=${1:?"no pkg path"}
    local pkgfullname=$(basename $pkgpath)
    local pkgname=${pkgfullname%.*} # remove extension
    
    echo "Type:           MPKG Bundle"
    
    IFS=$'\n'
    components=( $(find "$pkgpath" -iname '*.pkg') )
    components_count=${#components}
    echo "Contains $components_count component pkgs"
    echo
        
    for component in "${components[@]}"; do
        checkBundlePKG "$component" 1
    done
}

function checkComponentPKG() { # $1: pkgpath $2: level
    local pkgpath=${1:?"no pkg path"}
    local pkgfullname=$(basename $pkgpath)
    local pkgname=${pkgfullname%.*} # remove extension

    local level=${2:-0}
    if [[ level -gt 0 ]]; then
        indent="    "
        echo
        echo $indent$bold_color$pkgname$reset_color
        echo $indent$pkgpath
    else
        indent=""
    fi
    
    echo $indent"Type:           Flat Component PKG"

    # todo: determine identifier
    # todo: determine version
    
    local extractiondir="$scratchdir/$pkgname"
    if ! mkcleandir $extractiondir; then
        #echo "couldn't clean $extractiondir"
        return 1
    fi
    
    # does the pkg _have_ a Scripts archive
    if tar -tf "$pkgpath" Scripts &>/dev/null; then
        # extract the Scripts archive to scratch
        if ! tar -x -C "$extractiondir" -f "$pkgpath" Scripts; then
            #echo "error extracting Scripts Archive from $pkgpath"
            return 2
        fi
    
        # extract the resources from the Scripts archive
        if ! tar -x -C "$extractiondir" -f "$extractiondir/Scripts"; then
            #echo "error extracting Scripts from $extractiondir/Scripts"
            return 3
        fi
    
        # remove the ScriptsArchive
        rm "$extractiondir/Scripts"
    fi
    
    checkFilesInDir "$extractiondir" "$level"
    
    echo
}

function checkDistributionPKG() { # $1: pkgpath
    local pkgpath=${1:?"no pkg path"}
    local pkgfullname=$(basename $pkgpath)
    local pkgname=${pkgfullname%.*} # remove extension

    echo "Type:           Flat Distribution PKG"
    
    local pkgdir="$scratchdir/$pkgname"
        
    if ! mkcleandir $pkgdir; then
        #echo "couldn't clean $pkgdir"
        return 1
    fi
    
    # does the pkg _have_ Scripts archives?
    IFS=$'\n'
    components=( $(tar -tf "$pkgpath" '*.pkg$' 2>/dev/null) )
    components_count=${#components}
    echo "Contains ${#components} component pkgs"
    echo

    if [[ $components_count -gt 0 ]]; then
        for c in $components ; do
            # get the components's name
            local cname=${c%.*} # remove extension
            
            # create a subdir in extractiondir
            local extractiondir="$pkgdir/$cname"
            if ! mkcleandir "$extractiondir"; then
                #echo "couldn't clean $extractiondir"
                return 1
            fi
            
            echo "    $bold_color$cname$reset_color"
            echo "    Type:           Flat Component PKG"
            
            # todo: determine identifier
            # todo: determine version
            
            # does the pkg _have_ a Scripts archive
            if tar -tf "$pkgpath" "$c/Scripts" &>/dev/null; then
                # extract the Scripts archive to scratch
                if ! tar -x -C "$extractiondir" -f "$pkgpath" "$c/Scripts"; then
                    #echo "error extracting Scripts Archive from $pkgpath"
                    return 2
                fi
    
                # extract the resources from the Scripts archive
                if ! tar -x -C "$extractiondir" -f "$extractiondir/$c/Scripts"; then
                    #echo "error extracting Scripts from $extractiondir/$c/Scripts"
                    return 3
                fi
    
                # remove the ScriptsArchive
                rm -rf "$extractiondir/$c"
            fi
    
            # check the extracted scripts
            checkFilesInDir "$extractiondir" 1
            echo
        done
    fi
}

function checkPkg() { # $1: pkgpath
    local pkgpath=${1:?"no pkg path"}
    local pkgfullname=$(basename $pkgpath)
    local pkgname=${pkgfullname%.*} # remove extension

    type=""    

    # if extension is not pkg or mpkg: no pkg installer
    if [[ $pkgpath != *.(pkg|mpkg) ]]; then
        type="no_pkg"
        echo "$pkgname has no pkg or mpkg file extension"
        return 1
    fi
    
    echo $bold_color$pkgname$reset_color
    echo $pkgpath
    echo "Signature:      "$(getPkgSignature "$pkgpath")
    
    # mpkg extension : mpkg bundle type
    if [[ $pkgpath == *.mpkg ]]; then
        type="bundle_mpkg"
        checkBundleMPKG "$pkgpath"
        return 0
    fi
    
    # if it is a directory with a pkg extension it is probably a bundle pkg
    if [[ -d $pkgpath ]]; then
        type="bundle_pkg"
        checkBundlePKG "$pkgpath"
        return 0
    else
        # flat pkg, try to extract Distribution XML
        distributionxml=$(tar -xOf "$pkgpath" Distribution 2>/dev/null )
        if [[ $? == 0 ]]; then
            # distribution pkg, try to extract identifier
            identifier=$(xmllint --xpath "string(//installer-gui-script/product/@id)" - <<<${distributionxml})
            if [[ $? != 0 ]]; then
                # no identifier, normal distribution pkg
                type="flat_distribution"
            else
                type="flat_distribution_productarchive"
            fi
            checkDistributionPKG "$pkgpath"
            return 0
        else
            # no distribution xml, likely a component pkg
            type="flat_component"
            checkComponentPKG "$pkgpath"
            return 0
        fi
    fi

}

function checkDirectory() { # $1: dirpath
    local dirpath=${1:?"no directory path"}
    
    if [[ ! -d $dirpath ]]; then
        return 1
    fi
    
    IFS=$'\n'
    # find all pkg and mpkgs in the directory, excluding component pkgs in mpkgs
    for x in $(find "$dirpath" -not -ipath '*.mpkg/*' -and \( -iname '*.pkg' -or -iname '*.mpkg' \) ) ; do
        checkPkg "$x"
    done
}

# reset zsh
emulate -LR zsh

#set -x

# use sh behavior for word splitting
setopt shwordsplit

# load colors for nicer output
autoload -U colors && colors

# this script's dir:
scriptdir=$(dirname $0)

typeset -a scriptdirs
scriptdirs=( )

# scratch space
scratchdir="$scriptdir/scratch/"
if ! mkcleandir "$scratchdir"; then
    echo "couldn't clean $scratchdir"
    exit 1
fi

for arg in "$@"; do
    arg_ext="${arg##*.}"
    if [[ $arg_ext == "pkg" || $arg_ext == "mpkg" ]]; then
        checkPkg "$arg"
    elif [[ -d $arg ]]; then
        checkDirectory "$arg"
    else
        echo
        echo "$fg[red]pkgcheck: cannot process $arg$reset_color"
        echo
    fi
done

exit 0


# sample file
targetdir=${1:-"$scriptdir/SamplePkgs"}
if [[ ! -d $targetdir ]]; then
    echo "argument 1 should be a directory"
    exit 1
fi



IFS=$'\n'
for x in $(find "$targetdir" -not -ipath '*.mpkg/*' -and \( -iname '*.pkg' -or -iname '*.mpkg' \) ) ; do
    t=$(pkgType "$x")
    getScriptDirs "$x" "$t"
    echo $bold_color$x$reset_color
    echo "Type:          " $t
    echo "Signature:     " $(getPkgSignature "$x")
    #echo "Script Dirs:   " $scriptdirs
    for sdir in $scriptdirs; do
        #echo $sdir
        for f in $(find "$sdir" -type f ); do
            if [[ -e "$f" ]]; then
                if [[ $(file "$f") == *"script text executable"* ]]; then
                    shebang=$(head -n 1 "$f" | tr -d $'\n')
                    lastelement=${shebang##*/}
                    if [[ $shebang == "#!/bin/bash" || \
                          $shebang == "#!/usr/bin/python" || \
                          $shebang == "#!/usr/bin/ruby" || \
                          $shebang == "#!/usr/bin/perl" ]]; then
                        echo "$fg[yellow]$f has shebang $shebang$reset_color"
                    fi
                fi
            fi
        done
    done
    # add an empty line before the next pkg
    echo
done

# todo
# √ check if pkg is signed
# - check if pkg is notarized
# - get pkg version when available
# - get pkg identifier when available
# - when arg 1 ends in pkg or mpkg use that as the only target


