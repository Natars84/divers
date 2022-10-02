#!/bin/bash

adresseMACmanette="5C:BA:37:A5:E2:DA"

#####################################################################
#On attends jusqu'a ce que la Raspberry Pi soit connectée au reseau

echo "Verification de la connexion reseau"

etatReseau="down"
until [ $etatReseau = "up"  ]
do
        etatReseau=$(cat "/sys/class/net/eth0/operstate")
done

#####################################################################
#On tente de se connecter a manette XBOX jusqu'a ce que ca fonctionne

echo "Connexion a la manette: $adresseMACmanette"

bluetoothctl untrust $adresseMACmanette
connexionManette=1

until [ $connexionManette -eq 0 ]
do
        bluetoothctl connect $adresseMACmanette
        connexionManette=$?
done

bluetoothctl trust $adresseMACmanette

#####################################################################
#lancement de steamlink

echo "Lancement de SteamLink"
steamlink
