#Requires -Modules ActiveDirectory, GroupPolicy
<#
.SYNOPSIS
    Interface graphique pour associer des GPO à des utilisateurs AD,
    lancer la réplication AD et synchroniser OKTA via import incrémentiel.

.DESCRIPTION
    - Récupère les utilisateurs depuis LDAP
    - Récupère toutes les GPO du domaine
    - Permet la sélection multi-GPO / multi-utilisateurs via une UI WPF
    - Applique les GPO (liaison sur l'OU de l'utilisateur)
    - Lance une réplication AD vers tous les contrôleurs de domaine
    - Déclenche un import incrémentiel OKTA via l'API REST

.NOTES
    Prérequis : RSAT (ActiveDirectory + GroupPolicy), droits Domain Admin
    Variables OKTA à renseigner dans la section CONFIG
#>

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
$Config = @{
    # Base LDAP de recherche des utilisateurs
    LDAPSearchBase   = (Get-ADDomain).DistinguishedName

    # URL de base OKTA (ex: https://yourorg.okta.com)
    OktaBaseUrl      = "https://YOUR_ORG.okta.com"

    # Token API OKTA (stocker de préférence dans un secret manager)
    OktaApiToken     = "YOUR_OKTA_API_TOKEN"

    # ID de l'agent OKTA AD (visible dans Admin > Directory > Active Directory)
    OktaAgentId      = "YOUR_OKTA_AGENT_ID"
}

# ─────────────────────────────────────────────
# FONCTIONS HELPERS
# ─────────────────────────────────────────────
function Get-ADUserList {
    <# Récupère tous les utilisateurs activés depuis LDAP #>
    Get-ADUser -SearchBase $Config.LDAPSearchBase `
               -Filter { Enabled -eq $true } `
               -Properties DisplayName, SamAccountName, DistinguishedName |
        Sort-Object DisplayName
}

function Get-AllGPOs {
    <# Récupère toutes les GPO du domaine #>
    Get-GPO -All | Sort-Object DisplayName
}

function Get-OUFromDN ([string]$DistinguishedName) {
    <# Extrait l'OU parente depuis le DN d'un utilisateur #>
    ($DistinguishedName -split ',', 2)[1]
}

function Apply-GPOToUsers {
    param(
        [System.Collections.Generic.List[object]]$Users,
        [System.Collections.Generic.List[object]]$GPOs
    )

    foreach ($user in $Users) {
        $ou = Get-OUFromDN -DistinguishedName $user.DistinguishedName
        foreach ($gpo in $GPOs) {
            try {
                # Vérification si le lien existe déjà
                $existingLinks = Get-GPInheritance -Target $ou -ErrorAction Stop
                $alreadyLinked = $existingLinks.GpoLinks | Where-Object { $_.GpoId -eq $gpo.Id }

                if (-not $alreadyLinked) {
                    New-GPLink -Name $gpo.DisplayName -Target $ou -LinkEnabled Yes -ErrorAction Stop
                    Write-Host "[OK] GPO '$($gpo.DisplayName)' liée à l'OU '$ou'" -ForegroundColor Green
                } else {
                    Write-Host "[INFO] GPO '$($gpo.DisplayName)' déjà liée à '$ou'" -ForegroundColor Yellow
                }
            } catch {
                Write-Warning "[ERREUR] Impossible de lier '$($gpo.DisplayName)' à '$ou' : $_"
            }
        }
    }
}

function Invoke-ADReplication {
    <# Force la réplication AD vers tous les DCs du domaine #>
    $domain = Get-ADDomain
    $dcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName

    Write-Host "`n[RÉPLICATION] Lancement de la réplication AD..." -ForegroundColor Cyan

    foreach ($dc in $dcs) {
        try {
            repadmin /syncall $dc $domain.DistinguishedName /AdeP | Out-Null
            Write-Host "[OK] Réplication déclenchée sur $dc" -ForegroundColor Green
        } catch {
            Write-Warning "[ERREUR] Réplication échouée sur $dc : $_"
        }
    }
}

function Invoke-OktaIncrementalImport {
    <# Déclenche un import incrémentiel OKTA via l'API REST #>
    $headers = @{
        "Authorization" = "SSWS $($Config.OktaApiToken)"
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
    }

    $url = "$($Config.OktaBaseUrl)/api/v1/agents/active_directory/$($Config.OktaAgentId)/connected_objects/users/import"

    $body = @{ importType = "INCREMENTAL" } | ConvertTo-Json

    Write-Host "`n[OKTA] Déclenchement de l'import incrémentiel..." -ForegroundColor Cyan

    try {
        $response = Invoke-RestMethod -Uri $url -Method POST -Headers $headers -Body $body -ErrorAction Stop
        Write-Host "[OK] Import OKTA déclenché. Statut : $($response.status)" -ForegroundColor Green
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Warning "[ERREUR] Import OKTA échoué (HTTP $statusCode) : $_"
    }
}

# ─────────────────────────────────────────────
# INTERFACE GRAPHIQUE WPF
# ─────────────────────────────────────────────
function Show-MainUI {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AD GPO Manager + OKTA Sync"
        Height="620" Width="860"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E2E">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#7C3AED"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="#2A2A3E"/>
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#4A4A6A"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#A78BFA"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#2A2A3E"/>
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="BorderBrush" Value="#4A4A6A"/>
            <Setter Property="Padding" Value="4"/>
        </Style>
    </Window.Resources>
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="120"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Titre -->
        <TextBlock Grid.Row="0" Grid.ColumnSpan="2"
                   Text="AD GPO Manager · OKTA Incremental Sync"
                   FontSize="18" FontWeight="Bold"
                   Foreground="#A78BFA" Margin="0,0,0,12"/>

        <!-- Filtres -->
        <StackPanel Grid.Row="1" Grid.Column="0" Orientation="Horizontal" Margin="0,0,8,8">
            <Label Content="Filtre utilisateurs :" VerticalAlignment="Center"/>
            <TextBox Name="txtUserFilter" Width="180" Margin="4,0,0,0"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal" Margin="8,0,0,8">
            <Label Content="Filtre GPO :" VerticalAlignment="Center"/>
            <TextBox Name="txtGPOFilter" Width="180" Margin="4,0,0,0"/>
        </StackPanel>

        <!-- Liste Utilisateurs -->
        <DockPanel Grid.Row="2" Grid.Column="0" Margin="0,0,8,0">
            <Label DockPanel.Dock="Top" Content="Utilisateurs AD (multi-sélection)"/>
            <ListBox Name="lstUsers" SelectionMode="Extended"
                     DisplayMemberPath="DisplayName"
                     VirtualizingPanel.IsVirtualizing="True"/>
        </DockPanel>

        <!-- Liste GPO -->
        <DockPanel Grid.Row="2" Grid.Column="1" Margin="8,0,0,0">
            <Label DockPanel.Dock="Top" Content="GPO disponibles (multi-sélection)"/>
            <ListBox Name="lstGPOs" SelectionMode="Extended"
                     DisplayMemberPath="DisplayName"
                     VirtualizingPanel.IsVirtualizing="True"/>
        </DockPanel>

        <!-- Boutons d'action -->
        <StackPanel Grid.Row="3" Grid.ColumnSpan="2"
                    Orientation="Horizontal" HorizontalAlignment="Center"
                    Margin="0,12">
            <Button Name="btnApply" Content="✅  Appliquer les GPO" Margin="0,0,12,0"/>
            <Button Name="btnReplicate" Content="🔄  Répliquer AD" Margin="0,0,12,0"
                    Background="#0F766E"/>
            <Button Name="btnOkta" Content="☁  Sync OKTA" Background="#0369A1"/>
        </StackPanel>

        <!-- Log -->
        <DockPanel Grid.Row="4" Grid.ColumnSpan="2">
            <Label DockPanel.Dock="Top" Content="Journal d'exécution"/>
            <TextBox Name="txtLog" IsReadOnly="True" TextWrapping="Wrap"
                     VerticalScrollBarVisibility="Auto"
                     Background="#12121E" Foreground="#4ADE80" FontFamily="Consolas"/>
        </DockPanel>
    </Grid>
</Window>
"@

    $reader  = [System.Xml.XmlNodeReader]::new($xaml)
    $window  = [Windows.Markup.XamlReader]::Load($reader)

    # Références aux contrôles
    $lstUsers    = $window.FindName("lstUsers")
    $lstGPOs     = $window.FindName("lstGPOs")
    $txtUserFlt  = $window.FindName("txtUserFilter")
    $txtGPOFlt   = $window.FindName("txtGPOFilter")
    $txtLog      = $window.FindName("txtLog")
    $btnApply    = $window.FindName("btnApply")
    $btnReplicate= $window.FindName("btnReplicate")
    $btnOkta     = $window.FindName("btnOkta")

    # Chargement initial des données
    $allUsers = Get-ADUserList
    $allGPOs  = Get-AllGPOs

    $lstUsers.ItemsSource = [System.Collections.ObjectModel.ObservableCollection[object]]($allUsers)
    $lstGPOs.ItemsSource  = [System.Collections.ObjectModel.ObservableCollection[object]]($allGPOs)

    # Helper log
    $Log = { param($msg) $txtLog.AppendText("$(Get-Date -f 'HH:mm:ss')  $msg`r`n"); $txtLog.ScrollToEnd() }

    # Filtre utilisateurs
    $txtUserFlt.Add_TextChanged({
        $filter = $txtUserFlt.Text
        $filtered = $allUsers | Where-Object { $_.DisplayName -like "*$filter*" }
        $lstUsers.ItemsSource = [System.Collections.ObjectModel.ObservableCollection[object]]($filtered)
    })

    # Filtre GPO
    $txtGPOFlt.Add_TextChanged({
        $filter = $txtGPOFlt.Text
        $filtered = $allGPOs | Where-Object { $_.DisplayName -like "*$filter*" }
        $lstGPOs.ItemsSource = [System.Collections.ObjectModel.ObservableCollection[object]]($filtered)
    })

    # Bouton Appliquer GPO
    $btnApply.Add_Click({
        $selectedUsers = $lstUsers.SelectedItems
        $selectedGPOs  = $lstGPOs.SelectedItems

        if ($selectedUsers.Count -eq 0 -or $selectedGPOs.Count -eq 0) {
            & $Log "[AVERT] Veuillez sélectionner au moins un utilisateur ET une GPO."
            return
        }

        & $Log "[INFO] Application des GPO en cours..."
        Apply-GPOToUsers -Users $selectedUsers -GPOs $selectedGPOs
        & $Log "[OK] GPO appliquées à $($selectedUsers.Count) utilisateur(s)."
    })

    # Bouton Répliquer AD
    $btnReplicate.Add_Click({
        & $Log "[INFO] Démarrage de la réplication AD..."
        Invoke-ADReplication
        & $Log "[OK] Réplication AD terminée."
    })

    # Bouton Sync OKTA
    $btnOkta.Add_Click({
        & $Log "[INFO] Déclenchement de l'import incrémentiel OKTA..."
        Invoke-OktaIncrementalImport
        & $Log "[OK] Import OKTA lancé."
    })

    $window.ShowDialog() | Out-Null
}

# ─────────────────────────────────────────────
# POINT D'ENTRÉE
# ─────────────────────────────────────────────
Show-MainUI
