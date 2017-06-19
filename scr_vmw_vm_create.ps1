#####################################
# Auteur : Michael GEOFFRET
# Date de création : Janvier 2017
# 
# Description : Création d'une VM VMware depuis un template VMware
# 	- OS Supportés : Linux RHEL/CentOS
#	- Fichier entrée : VMName.conf
#	- Actions : Creation DNS, définition des propriétés VM (LAN, Datastore, ESX...), provisioning depuis template, customisation VM, création du KS pour installation Linux
#
# Prérequis
#	- PowerShell >= 3.0
#####################################
# Fonctions

function f_usage {
	write-host "Usage : vmw_vm_create.ps1 <vmName>"
	stop-transcript
	exit 1
}

function f_exit {
	stop-transcript
	exit 1
}

function f_findDNSServer {
	$netWorks=Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter IPEnabled=TRUE | where-object {$_.DNSDomain -eq ${DOMAIN}}
	$dnsServer=foreach($netWork in ${netWorks}) {${network}.DNSServerSearchOrder |select -first 1 }
}

function f_checkPSHVersion {
	if ( (get-host).version.major -ne ${PSHVersionMin} ) { write-host -BackgroundColor Red "[ERROR] : Version de Powershell incompatible ou non validée ; Version ${PSHVersionMin} requise." ; f_exit }
}

function f_checkPowerCLIVersion {
	if ( (Get-Module -ListAvailable VMware.VimAutomation.Core).Version -ne ${PowerCLIVersionMin} ) { write-host -BackgroundColor Red "[ERROR] : Version de PowerCLI incompatible ou non validée ; Version ${PowerCLIVersionMin} requise." ; f_exit }
}

function f_loadcmdlets {
	param([string]$cmdlets)
	if (!(Get-PSSnapin |where-object {$_.name -eq $cmdlets})) {
		write-host "[INFO] : Cmdlets non chargées. Chargement..."
		$p = [Environment]::GetEnvironmentVariable("PSModulePath")
		$p += ";C:\Program Files (x86)\VMware\Infrastructure\PowerCLI\Modules\"
		[Environment]::SetEnvironmentVariable("PSModulePath",$p)
		#. “C:\Program Files (x86)\VMware\Infrastructure\PowerCLI\Scripts\Initialize-PowerCLIEnvironment.ps1”
		Import-Module $cmdlets
		if ( ! (Get-Module -ListAvailable ${cmdlets} )) {write-host -BackgroundColor Red "[ERROR] : PowerCLI non trouvée" ; f_exit}
	}
	#if (!(Get-PSSnapin |where-object {$_.name -eq $cmdlets})) {Write-Host "[ERROR] :" $cmdlets "introuvable."}
}

function f_connectVI {
	param([string]$server, [string]$user , [string]$password)
	write-host "[INFO] : Connexion au serveur" $server "..."
	if (!($user) -and !($password)){
		$credentials = Get-Credential
		$cnx = Connect-VIServer -Server $server -Credential $credentials
	}
		else {$cnx = Connect-VIServer -Server $server -user $user -Password $password} 
	if (!($cnx)){Write-Host "[ERROR] : Echec de la connexion au" $server"." -foregroundcolor Red ; Remove-Variable $cnx ; return 1}
		else {write-host "[INFO] : Connexion au" $server ": OK"}
}

function f_disconnectVI {
	disConnect-VIServer -Confirm:$False
}

function f_testDispoVM {
	# Test disponibilité vmName, Nom DNS et IP
	Write-host "[INFO] : Controle de la disponibilité vmName, Nom DNS et IP..."
	$vmTestDNS=nslookup ${vmName} |Select-String ${vmName}
	if (${vmTestDNS}) { write-host -BackgroundColor Red "[ERROR] : ${vmName} déjà référencée dans le DNS." ; f_exit }
	$vmTestDNS=nslookup ${vmIP1} |Select-String ${vmIP1}
	if (${vmTestDNS}) { write-host -BackgroundColor Red "[ERROR] : ${vmName} déjà référencée dans le DNS." ; f_exit }
	if ( get-vm ${vmName} 2> out-null ) { write-host -BackgroundColor Red "[ERROR] : ${vmName} déjà référencée dans le ${VCENTER}." ; f_exit }
	if (Get-ADComputer ${vmName}) {write-host -BackgroundColor Red "Serveur ${vmName} existant dans l'AD." ; f_exit }
}

function f_vmCreate {
	Write-host ""
	Write-host "[${date}][INFO] : Création de la VM ${vmName} sur ${vmSite}..."
	Write-host ""

	# Enregistrement dans le DNS
	Write-host "[INFO] : Enregistrement dans le DNS..."
	if ( ! (dnscmd ${dnsServer} /Recordadd ${DOMAIN} ${vmName} /CreatePTR A ${vmIP1}) ) {write-host -BackgroundColor Red "[ERROR] : Erreur d'enregistrement ${vmName} dans le DNS." ; f_exit}
	if ( ${vmAlias} ) { if ( ! ( dnscmd ${dnsServer} /recordadd ${DOMAIN} ${vmAlias} CNAME "${vmName}.${DOMAIN}." ) ) {write-host -BackgroundColor Red "[ERROR] : Erreur d'enregistrement ${vmAlias} dans le DNS."} }
	if ($vmIPTech) {
		if ( ! (dnscmd ${dnsServer} /Recordadd ${DOMAIN} ${vmName}t /CreatePTR A ${vmIPTech}) ) {write-host -BackgroundColor Red "[ERROR] : Erreur d'enregistrement ${vmName}t dans le DNS."}
		if ( ${vmAlias} ) { if ( ! ( dnscmd ${dnsServer} /recordadd ${DOMAIN} ${vmAlias}t CNAME "${vmName}t.${DOMAIN}." ) ) {write-host -BackgroundColor Red "[ERROR] : Erreur d'enregistrement ${vmAlias}t dans le DNS."} }
	}

	# Création de la VM
	Write-host "[INFO] : Création de la VM..."
	New-VM -VMHost ${vmESX} -Name ${vmName} -NumCpu ${vmDefaultCPU} -MemoryGB ${vmDefaultRAM} -Datastore ${vmDatastore} -DiskGB ${vmHDSys},${vmHDLogs},${vmHDAdmin} -StorageFormat ${vmHDdefaultFormat} -GuestId ${vmGuestId} -CD -Notes ${vmNotes} |out-null

	# Personnalisation du CPU et de la RAM
	if (${vmCPU}) {
		Write-host "[INFO] : Configuration CPU..."
		Set-VM -VM ${vmName} -NumCpu ${vmCPU} -confirm:$false |out-null
	}
	if (${vmRAM}) {
		Write-host "[INFO] : Configuration RAM..."
		Set-VM -VM ${vmName} -MemoryGB ${vmRAM} -confirm:$false |out-null
	}
	# Mise en cohérence du VLAN avec l'IP/Env de la VM
	Write-host "[INFO] : Configuration VLAN ${vmVLAN}..."
	Get-VM ${vmName} | Get-NetworkAdapter -Name "Adaptateur réseau 1" | Set-NetworkAdapter -NetworkName ${vmVLAN} -confirm:$false |out-null
	
	# Ajout des disques supplémentaires
	if (${vmTabHDSize}) {
		Write-host "[INFO] : Ajout des disques supplémentaires..."
		foreach ( ${HDSize} in ${vmTabHDSize} ) { Get-VM ${vmName} | New-HardDisk -CapacityGB ${HDSize} -StorageFormat ${vmHDdefaultFormat} -confirm:$false |out-null}
	}
	
	# Configuration ajout à chaud CPU et RAM
	Write-host "[INFO] : Configuration Hot Add CPU/RAM..."
	$vmConfigExtraKeys=("vcpu","mem")
	foreach ( ${key} in ${vmConfigExtraKeys} ) { Enable-HotAdd ${key} }

	# Connexion du CDROM d'installation
	Write-host "[INFO] : Connexion de l'ISO de ${vmOSDistribution} ${vmOSVersion} ${vmOSARCH} au lecteur CD-Rom..."
	Get-VM ${vmName} | Get-CDDrive | Set-CDDrive -ISOPath "${vmISO}" -Startconnected 1 -confirm:$false |out-null
}

function f_ksCreate {
	# Creation du ks sur lxinst01
	Write-host "[INFO] : Création du fichier ks..."
	copy-item \\${vmLxInstall}\ks\${vmKsTemplate} \\${vmLxInstall}\prov\${vmName}.cfg
	cd \\${vmLxInstall}\prov\
	$vmFileCfgTmp="${vmName}tmp"

	$releasever=$vmOSVersion |%{ $_.split(".")[0]}

	(Get-Content .\${vmName}.cfg -raw).Replace('##RELEASEVER##',${releasever}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##OSVER##',${vmOSVersion}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##OSARCH##',${vmOSARCH2}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##HOSTNAME##',${vmName}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##IP##',${vmIP1}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##NET##',${vmNet1}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##GATEWAY##',${vmGateway}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##DNS##',${vmDNS}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##ENV##',${vmENVRundeck}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##ENVL2##',${vmENVRundeckL2}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##ALIASNAME##',${vmAlias}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##SITE##',${vmSite}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##DESCRIPTION##',${vmDes}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##TAGS##',${vmTags}) | set-Content .\${vmName}.cfg -force
	(Get-Content .\${vmName}.cfg -raw).Replace('##POSTSH##',${vmPostSh}) | set-Content .\${vmName}.cfg -force
	if ($vmIPTech) {(Get-Content .\${vmName}.cfg -raw).Replace('##IPTECH##',${vmIPTech}) | set-Content .\${vmName}.cfg -force}
	(Get-Content .\${vmName}.cfg -raw).Replace("`r`n","`n") | Set-Content .\${vmName}.cfg -Force
	
	copy-item \\${vmLxInstall}\prov\${vmName}.cfg \\${vmLxInstall}\prov\ks.cfg
}

Function Enable-HotAdd(${key}){
	$vmview = Get-VM ${vmName} | Get-View
	$vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
	$extra = New-Object VMware.Vim.optionvalue
	$extra.Key="${key}.hotadd"
	$extra.Value="true"
	$vmConfigSpec.extraconfig += ${extra}
	$vmview.ReconfigVM(${vmConfigSpec})
}

#####################################
# Main
#####################################

$vmtmp=$args[0]
start-transcript -path install_${vmtmp}.log -confirm:$false
# Check des arguments

$startDrive=${pwd}.Drive.Name

if ($args.count -ne 1) {f_usage}

$ErrorActionPreference = 'SilentlyContinue'

$PSHVersionMin=3
$PowerCLIVersionMin=6.5
$DOMAIN = "domvie.fr"
$SMTP_SERVER = "srvmail"
$VMWCMDLETS = "VMware.VimAutomation.Core"
$VCENTER = "vcenter01." + ${DOMAIN}
$VCENTER_USER = "domvie\vmw-service"
$VCENTER_PASSWD = "Yn62452U"
$CLUSTER_BESSINES="TITANIUM"
$CLUSTER_CHAURAY="SILVER"
$DS_ISO_BESSINES="STK04_vv_vmw_vmfs_009"
$DS_ISO_CHAURAY="STK05_vv_vmw_vmfs_006"
$DNS_BESSINES="10.100.7.5,10.100.7.50"
$DNS_CHAURAY="192.168.11.25"
$STK_BESSINES="stk04"
$STK_CHAURAY="stk05"

$vmLxInstall="lxinst01." + ${DOMAIN}
$vmNamePrefixLx="lxapps"
$vmNamePatternLx="${vmNamePrefixLx}NNN"
$vmNetNoPRD="255.255.255.0"
$vmNetPRD="255.255.254.0"
$vmNotesPRD="113" 
$vmNotesPPR="001" 
$vmNotesFOR="113" 
$vmNotesREC="013" 
$vmNotesDEV="011"
$vmNotesTST="000" 

$vmDefaultCPU="1"
$vmDefaultRAM="2"

# Check de la version PowerShell
f_checkPSHVersion

# Chargement ddes commandlets PowerCLI
f_loadcmdlets -c ${VMWCMDLETS}

# Check de la version PowerCLI
#f_checkPowerCLIVersion

# Recherche du DNS Server primaire
f_findDNSServer

# Suppression de toutes connexions actives
while ($global:DefaultVIServers.Count -gt 0){$global:DefaultVIServers | Disconnect-VIServer -confirm:$false}

# Si PS lancé en tant qu'administrateur
Connect-VIServer -Server ${VCENTER} -user ${VCENTER_USER} -Password ${VCENTER_PASSWD}

clear

Write-host "[INFO] : VM PROVISIONING"
Write-host "========================="
Write-host "[INFO] : Contrôle des prérequis..."
$vmName = $args[0]
$vmName = echo ${vmName}.toLower()

# Test du nom de la VM passé
if ( ${vmName}.Length -ne 9 -or ${vmName} -notlike "${vmNamePrefixLx}*" -or ${vmName}.Substring($vmName.Length-3 ) -notmatch '^\d+$' ) {write-host "[ERROR] : Le nom de la VM doit être du type ${vmNamePatternLx}." ; f_exit}

# Test si le fichier de conf existe
if ( ! (Test-Path .\${vmName}.conf) ) { write-host -BackgroundColor Red "[ERROR] : Fichier ${vmName}.conf introuvable." ; f_exit }
mv .\${vmName}.conf .\${vmName}.ps1 ; . .\${vmName}.ps1 ;mv .\${vmName}.ps1 .\${vmName}.conf

# Controle des données saisies
if ( ! $vmServerTemplate ) { write-host -BackgroundColor Red "[ERROR] : Template Serveur non défini." ; f_exit }
if ( ! $vmKsTemplate ) { write-host -BackgroundColor Red "[ERROR] : Template ks non défini." ; f_exit }
if ( ! $vmSite ) { write-host -BackgroundColor Red "[ERROR] : Site non défini." ; f_exit }
if ( ! $vmDatastoreClassDisks ) { write-host -BackgroundColor Red "[ERROR] : Class Disk non définie." ; f_exit }
if ( ! $vmENV ) { write-host -BackgroundColor Red "[ERROR] : Environnement non défini." ; f_exit }
if ( ! $vmOSFamily ) { write-host -BackgroundColor Red "[ERROR] : Famille d'OS non définie." ; f_exit }
if ( ! $vmOSDistribution ) { write-host -BackgroundColor Red "[ERROR] : Distribution non définie." ; f_exit }
if ( ! $vmOSVersion ) { write-host -BackgroundColor Red "[ERROR] : Version OS non définie." ; f_exit }
if ( ! $vmOSARCH ) { write-host -BackgroundColor Red "[ERROR] : Architecture OS non définie." ; f_exit }
if ( ! $vmIP1 ) { write-host -BackgroundColor Red "[ERROR] : IP non définie." ; f_exit }
if ( ! $vmENVRundeckL2 ) { write-host -BackgroundColor Red "[ERROR] : ENVL2 non défini." ; f_exit }
if ( ! $vmHDdefaultFormat ) { write-host -BackgroundColor Red "[ERROR] : Format Disque non défini." ; f_exit }
if ( ! $vmHDSys ) { write-host -BackgroundColor Red "[ERROR] : Taille disque OS non définie." ; f_exit }
if ( ! $vmHDLogs ) { write-host -BackgroundColor Red "[ERROR] : Taille disque /logs non définie." ; f_exit }
if ( ! $vmHDAdmin ) { write-host -BackgroundColor Red "[ERROR] : Taille disque /admin non définie." ; f_exit }

$date = date -format dd/MM/yyyy-HH:mm:ss

f_testDispoVM

# Mise en conformité des données saisies
$vmKsTemplate = echo ${vmKsTemplate}.toLower()
$vmServerTemplate = echo ${vmServerTemplate}.toLower()
$vmSite = echo ${vmSite}.substring(0,1).toupper()+${vmSite}.substring(1).tolower() 
$vmESX = echo ${vmESX}.toLower()
$vmENV = echo ${vmENV}.toUpper()
$vmOSFamily = echo ${vmOSFamily}.toLower()
$vmOSDistribution = echo ${vmOSDistribution}.toLower()
if ( ${vmAlias} ) {$vmAlias = echo ${vmAlias}.toLower()}
$vmENVRundeckL2 = echo ${vmENVRundeckL2}.toLower()
$vmTags = echo ${vmTag}.toLower()

# Construction des variables
$vmDatacenter = echo ${vmSite}.toUpper()
$vmENVRundeck = echo ${vmENV}.toLower()
$vmPostSh=${vmServerTemplate} # -split("lxskel-"))[1]
if ( ! (Test-Path \\${vmLxInstall}\ks\${vmKsTemplate}) ) { write-host "[ERROR] : Fichier ${vmKsTemplate} introuvable." ; f_exit }

switch (${vmOSARCH})
	{
	32 {$vmOSARCH2="i386" ; $vmOSARCHGuest=""} 
	64 {$vmOSARCH2="x86_64" ; $vmOSARCHGuest="${vmOSARCH}"} 
	default {write-host -BackgroundColor Red "[ERROR] : Architecture OS non prise en charge." ; f_exit}
	}
	
$vmOSVersionMaj = ${vmOSVersion} |%{ $_.split(".")[0]}

switch (${vmOSDistribution})
	{
	rhel {$vmGuestId = "${vmOSDistribution}${vmOSVersionMaj}_${vmOSARCHGuest}Guest"} 
	centos {$vmGuestId = "${vmOSDistribution}${vmOSVersionMaj}_${vmOSARCHGuest}Guest"} 
	windows {$vmGuestId = "${vmOSDistribution}${vmOSVersionMaj}${vmOSARCHGuest}Guest"} 
	}

$vmGuestId = "${vmOSDistribution}${vmOSVersionMaj}_${vmOSARCHGuest}Guest"

switch (${vmsite})
	{
		Bessines {
			switch (${vmOSFamily})
			{
				linux {$vmISO="[${DS_ISO_BESSINES}] ISO/${vmOSFamily}/${vmOSDistribution}/${vmOSDistribution}-server-${vmOSVersion}-${vmOSARCH2}-dvd.iso"}
				default {write-host -BackgroundColor Red "[ERROR] : ${vmOSFamily} actuellement non pris en charge." ; f_exit}
			}	
			switch (${vmENV})
			{
				PRD {$vmVLAN="LAN_PRD_UX" ; $vmIPPattern="10.10.2" ; $vmNet1=${vmNetPRD} ; $vmNotes="${vmENV} ; ${vmNotesPRD} ; ${vmDes}" }
				PPR {$vmVLAN="LAN_PPRD_UX" ; $vmIPPattern="10.10.12" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesPPR} ; ${vmDes}" }
				FOR {$vmVLAN="LAN_FOR_UX" ; $vmIPPattern="10.10.52" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesFOR} ; ${vmDes}" }
				REC {$vmVLAN="LAN_REC_UX" ; $vmIPPattern="10.10.22" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesREC} ; ${vmDes}" }
				DEV {$vmVLAN="LAN_DEV_UX" ; $vmIPPattern="10.10.32" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesDEV} ; ${vmDes}" }
				TST {$vmVLAN="LAN_TST_UX" ; $vmIPPattern="10.10.62" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesTST} ; ${vmDes}" }
				default {write-host -BackgroundColor Red "[ERROR] : Environnement non pris en charge." ; f_exit}
			}
			$vmDNS = "${DNS_BESSINES},${DNS_CHAURAY}"
			$stkPref=${STK_BESSINES}
			$vmCluster=${CLUSTER_BESSINES}
		}
		Chauray {
			switch (${vmOSFamily})
			{
				linux {$vmISO="[${DS_ISO_CHAURAY}] ISO/${vmOSFamily}/${vmOSDistribution}/${vmOSDistribution}-server-${vmOSVersion}-${vmOSARCH2}-dvd.iso"}
				default {write-host -BackgroundColor Red "[ERROR] : ${vmOSFamily} actuellement non pris en charge." ; f_exit}
			}	
			switch (${vmENV})
			{
				PRD {$vmVLAN="LAN" ; $vmIPPattern="192.168.11" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesPRD} ; ${vmDes}" }
				PPR {$vmVLAN="LAN" ; $vmIPPattern="192.168.11" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesPPR} ; ${vmDes}" }
				FOR {$vmVLAN="LAN" ; $vmIPPattern="192.168.11" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesFOR} ; ${vmDes}" }
				REC {$vmVLAN="LAN" ; $vmIPPattern="192.168.11" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesREC} ; ${vmDes}" }
				DEV {$vmVLAN="LAN" ; $vmIPPattern="192.168.11" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesDEV} ; ${vmDes}" }
				TST {$vmVLAN="LAN" ; $vmIPPattern="192.168.11" ; $vmNet1=${vmNetNoPRD} ; $vmNotes="${vmENV} ; ${vmNotesTST} ; ${vmDes}" }
				default {write-host -BackgroundColor Red "[ERROR] : Environnement non pris en charge." ; f_exit}
			}
			$vmDNS = "${DNS_CHAURAY},${DNS_BESSINES}"
			$stkPref=${STK_CHAURAY}
			$vmCluster=${CLUSTER_CHAURAY}
		}
		default {write-host -BackgroundColor Red "[ERROR] : Site non pris en charge." ; f_exit}
}

$vmGateway="${vmIPPattern}.1"

Write-host ""
if ( ! ${vmESX} ) {
	Write-host "[INFO] : Aucun ESX renseigné => sélection automatique..."
	$vmHosts=get-datacenter ${vmDatacenter}|get-cluster CLUSTER_${vmCluster} | get-VMHost
	rm esx.list
	foreach ($esx in ${vmHosts}) { $esxMemoryFreeGB=${esx}.MemoryTotalGB-${esx}.MemoryUsageGB ; $esxName=${esx}.Name ;  write  "${esxName};${esxMemoryFreeGB}" >> esx.list}
	$vmESX=cat esx.list | Sort-Object { [double]$_.split()[-1] } -Descending |select -first 1 | %{ $_.split(";")[0]}
	Write-host "`t=> Host : ${vmESX}"

}

if ( ! ${vmDatastore} ) {
	Write-host "[INFO] : Aucun Datastore renseigné => sélection automatique..."
	$dsList=get-datacenter ${vmDatacenter}|get-datastore ${stkPref}_vv_vmw_vmfs_0* |where {$_.FileSystemVersion -gt 5}
	$dsList=foreach (${datastore} in ${dsList}) { if ( (Get-TagAssignment -Entity ${datastore}) -like "*${vmDatastoreClassDisks}*" ) {${datastore}} }
	if (! ${dsList} ) { write-host -BackgroundColor Red "[ERROR] : Aucun Datastore ${vmDatastoreClassDisks} trouvé sur ${stkPref}." ; f_exit }
	$vmDatastore = (${dsList} |Sort-Object -Property FreeSpaceGB -descending |select -first 1).name
	$vmHDSize = [int]${vmHDSys} + [int]${vmHDLogs} + [int]${vmHDadmin}
	if ( ${vmTabHDSize}[0] -ne 0 ) {
		foreach ( ${HDSize} in ${vmTabHDSize} ) {
			if ( ${HDSize} -eq 0 ) { write-host -BackgroundColor Red "[ERROR] : Taille de disque supplémentaire à 0." ; f_exit}
			$vmHDSize = ${vmHDSize} + [int]${HDSize}
		}
	}
	else { write-host "Pas de disques supplémentaires" }
	if ( ${vmHDSize} -ge [int](Get-Datastore ${vmDatastore}).FreeSpaceGB ) {write-host -BackgroundColor Red "[ERROR] : Aucun datastore avec espace suffisant. Template : ${vmHDSize}Go"; f_exit }
	Write-host "`t=> Datastore : ${vmDatastore}"
}

# Création de la VM
f_vmCreate

# Création du kickstart
f_ksCreate

# Retour au path précédent
cd "${startDrive}:"

Write-host ""
$date = date -format dd/MM/yyyy-HH:mm:ss
Write-host -BackgroundColor Green -ForegroundColor Black "[${date}][INFO] : Création de la VM ${vmName} sur ${vmSite} terminée."
Write-host ""

if ( ${vmInstallNow} -eq 1) {
	Write-host "[INFO] : Installation post provisioning demandée..."
	Write-host "[INFO] : Démarrage de la VM ${vmName}..."
	start-vm ${vmName} |out-null
}
else {
	Write-host -Nonewline "Faire un start VM depuis le vCenter et passer la commande suivante en CLI : "
}
f_disconnectVI

stop-transcript

exit 0








