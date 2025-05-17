#!/bin/bash

# --- Performans Ayarları (Kullanıcı tarafından değiştirilebilir) ---
# Linux'ta oflag=direct kullanılsın mı? (true/false)
# 'true': Önbelleği bypass eder, ilerleme daha doğru olur ama bazen daha yavaş olabilir.
# 'false': Önbelleği kullanır, başlangıçta hızlı görünebilir, sonda yavaşlayabilir ama toplamda daha hızlı olabilir.
LINUX_USE_OFLAG_DIRECT=true

# dd için blok boyutu. Örn: 1M, 4M, 8M, 16M, 64M, 128M
# Farklı değerler deneyerek sisteminiz ve hedef aygıtınız için en iyi hızı bulun.
DD_BLOCK_SIZE="128M"

# pv için güncelleme aralığı (saniye). Daha yüksek değer, daha az güncelleme, potansiyel olarak daha az ek yük.
PV_UPDATE_INTERVAL=5
# --- Performans Ayarları Sonu ---


function find_disk() {
    echo "--------------------------------------------------------------------"
    echo "Kullanılabilir blok aygıtları listeleniyor..."
    echo "--------------------------------------------------------------------"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macOS Diskleri (diskutil list çıktısı):"
        diskutil list
        echo ""
        echo "macOS'ta disk adını bulmak için (yukarıdaki listeye bakın):"
        echo "1. Hedef diskinizi listeden tanımlayın (örn: /dev/disk6)."
        echo "   Bir bölümü değil (örn: disk6s1 bir bölümdür), *tüm* diskin TANIMLAYICISINA bakın."
        echo "   Diskinizi doğru bir şekilde tanımlamak için BOYUT ve AD bilgilerine dikkat edin."
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "Linux Diskleri (lsblk -d -o NAME,SIZE,MODEL,VENDOR,TRAN,TYPE,PATH çıktısı):"
        lsblk -d -o NAME,SIZE,MODEL,VENDOR,TRAN,TYPE,PATH
        echo ""
        echo "Linux'ta disk adını bulmak için (yukarıdaki listeye bakın):"
        echo "1. Hedef diskinizi NAME veya PATH sütunundan tanımlayın (örn: /dev/sdb, /dev/nvme0n1)."
        echo "   Bir bölümü değil, tüm disk aygıtını seçtiğinizden emin olun ('lsblk -d' ile bölümler genellikle gösterilmez)."
        echo "   BOYUT, MODEL ve usb, sata, nvme gibi taşıma türüne (TRAN) dikkat edin."
    else
        echo "Desteklenmeyen işletim sistemi: $OSTYPE"
        echo "Diskler otomatik olarak listelenemiyor. Lütfen diskinizi manuel olarak tanımlayın."
        echo "'pv' kuruluysa ilerleme raporlaması yine de çalışabilir."
    fi
    echo "--------------------------------------------------------------------"
}

find_disk # Diskleri ve talimatları göstermek için fonksiyonu çağır

read -p "Yazmak istediğiniz disk adını girin (örn: /dev/disk6 veya /dev/sdb): " disk_name
img_path_default="img.img" # Varsayılan imaj dosyası adı
img_path="$img_path_default"

# macOS: /dev/diskX girildiyse /dev/rdiskX kullanmayı öner
if [[ "$OSTYPE" == "darwin"* ]] && [[ "$disk_name" =~ ^/dev/disk([0-9]+)$ ]]; then
    rdisk_name="/dev/rdisk${BASH_REMATCH[1]}"
    read -p "macOS'ta '$rdisk_name' (raw disk) kullanmak genellikle daha hızlıdır. '$disk_name' yerine '$rdisk_name' kullanılsın mı? (yes/NO): " use_rdisk
    if [[ "$use_rdisk" == "yes" ]]; then
        disk_name="$rdisk_name"
        echo "Raw disk kullanılıyor: $disk_name"
    fi
fi


# Varsayılan imaj dosyası yoksa, yolunu sor
if [[ ! -f "$img_path" ]]; then
    echo "Varsayılan imaj '$img_path_default' geçerli dizinde bulunamadı."
    read -p "Lütfen imaj dosyanızın tam yolunu girin: " custom_img_path
    if [[ ! -f "$custom_img_path" ]]; then
        echo "Hata: İmaj dosyası '$custom_img_path' bulunamadı. Çıkılıyor."
        exit 1
    fi
    img_path="$custom_img_path"
fi

echo "Kullanılan imaj dosyası: $img_path"
echo "Kullanılacak dd blok boyutu: $DD_BLOCK_SIZE"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Linux için oflag=direct ayarı: $LINUX_USE_OFLAG_DIRECT"
fi


# pv kurulu mu kontrol et
if ! command -v pv &> /dev/null; then
    echo ""
    echo "--------------------------------------------------------------------"
    echo "Uyarı: 'pv' (Pipe Viewer) kurulu değil. İlerleme yüzdesi ve ETA gösterilemeyecek."
    echo "'pv' olmadan, sadece temel 'dd' durumu gösterilebilir (bazı Linux sistemlerinde)."
    echo ""
    echo "'pv' kurmak için:"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  macOS'ta (Homebrew kullanarak): brew install pv"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "  Debian/Ubuntu'da: sudo apt-get update && sudo apt-get install pv"
        echo "  Fedora/RHEL'de: sudo dnf install pv  (veya sudo yum install pv)"
    fi
    echo "--------------------------------------------------------------------"
    echo ""
    read -p "Detaylı ilerleme olmadan devam etmek istiyor musunuz? (yes/no): " continue_without_pv
    if [[ "$continue_without_pv" != "yes" ]]; then
        echo "Çıkılıyor. Lütfen 'pv' kurup tekrar deneyin."
        exit 1
    fi
    PV_INSTALLED=false
else
    PV_INSTALLED=true
    # pv için imaj boyutunu al
    if [[ "$OSTYPE" == "darwin"* ]]; then
        img_size=$(stat -f%z "$img_path")
    else # linux-gnu veya stat -c%s destekleyen diğer Unix benzeri sistemler varsayılıyor
        img_size=$(stat -c%s "$img_path")
    fi

    if ! [[ "$img_size" =~ ^[0-9]+$ ]] || [[ "$img_size" -eq 0 ]]; then
        echo "Hata: '$img_path' dosyasının boyutu belirlenemedi veya dosya boş. Çıkılıyor."
        exit 1
    fi
fi


# Disk adını doğrula (temel kontrol)
if [[ -z "$disk_name" ]]; then
    echo "Hata: Disk adı boş olamaz. Çıkılıyor."
    exit 1
fi

# Disk kalıpları için daha spesifik doğrulama
if [[ "$OSTYPE" == "darwin"* ]]; then
    # /dev/rdiskX veya /dev/diskX olmalı
    if ! [[ "$disk_name" =~ ^/dev/(r?disk)[0-9]+$ ]]; then
        echo "Uyarı: macOS'ta, bir bütün disk için disk adı /dev/diskX veya /dev/rdiskX gibi olmalıdır (örn: /dev/disk6, /dev/rdisk6)."
        echo "Girdiğiniz: '$disk_name'. Lütfen bunun doğru *bütün disk tanımlayıcısı* olduğundan ve bir bölüm olmadığından emin olun."
    fi
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux'ta bütün diskler için yaygın kalıplar
    if ! [[ "$disk_name" =~ ^/dev/sd[a-z]+$ || \
            "$disk_name" =~ ^/dev/nvme[0-9]+n[0-9]+$ || \
            "$disk_name" =~ ^/dev/mmcblk[0-9]+$ || \
            "$disk_name" =~ ^/dev/xvd[a-z]+$ || \
            "$disk_name" =~ ^/dev/vd[a-z]+$ ]]; then
        echo "Uyarı: Linux'ta, bir bütün disk için disk adı genellikle /dev/sdx, /dev/nvmeXnY, /dev/mmcblkX, /dev/xvdx veya /dev/vdx gibidir."
        echo "Girdiğiniz: '$disk_name'. Lütfen bunun doğru *bütün disk tanımlayıcısı* olduğundan ve bir bölüm (örn: /dev/sda1) olmadığından emin olun."
    fi
fi


read -p "'$img_path' dosyasını '$disk_name' diskine yazmak istediğinizden KESİNLİKLE emin misiniz? Bu işlem '$disk_name' üzerindeki TÜM VERİLERİ SİLECEKTİR. Onaylamak için 'EVET' yazın: " confirmation
if [[ "$confirmation" != "EVET" ]]; then # Büyük harf EVET gerektir
    echo "İşlem kullanıcı tarafından iptal edildi."
    exit 0
fi

echo "'$disk_name' diski veya bölümlerinin kullanımda/bağlı olup olmadığı kontrol ediliyor..."
# Bağlantıyı kesme mantığı
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "'$disk_name' (macOS) üzerindeki tüm birimlerin bağlantısı kesilmeye çalışılıyor..."
    if ! diskutil unmountDisk "$disk_name"; then
        echo "Hata: macOS'ta '$disk_name' diskinin bağlantısı kesilemedi. Kullanımda olabilir veya tanımlayıcı yanlış olabilir."
        echo "Lütfen diski kullanan işlemler için Etkinlik Monitörü'nü kontrol edin veya disk tanımlayıcısını doğrulayın."
        echo "Emin olduğunuz takdirde manuel olarak 'sudo diskutil unmountDisk force $disk_name' komutunu deneyebilirsiniz."
        exit 1
    else
        echo "'$disk_name' (macOS) üzerindeki tüm birimlerin bağlantısı başarıyla kesildi."
    fi
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "'$disk_name' (Linux) üzerindeki bölümlerin bağlantısı kesilmeye ve takas alanı (swap) devre dışı bırakılmaya çalışılıyor..."
    PARTS_TO_UNMOUNT=$(lsblk -lnro NAME,TYPE,MOUNTPOINT "$disk_name" | awk '$2~/part|lvm|md/ && ($3!="" || $3=="[SWAP]") {print $1}')

    if [[ -n "$PARTS_TO_UNMOUNT" ]]; then
        for part_name in $PARTS_TO_UNMOUNT; do
            local_part_path="/dev/$part_name"
            mount_info=$(lsblk -lnro MOUNTPOINT,TYPE "$local_part_path")
            current_mountpoint=$(echo "$mount_info" | awk '{print $1}')
            # fs_type=$(echo "$mount_info" | awk '{print $2}') # fs_type şu an kullanılmıyor ama bilgi olarak alınabilir

            if [[ "$current_mountpoint" == "[SWAP]" ]]; then
                echo "$local_part_path üzerindeki takas alanı devre dışı bırakılıyor..."
                if ! sudo swapoff "$local_part_path"; then
                    echo "Hata: $local_part_path üzerindeki takas alanı devre dışı bırakılamadı. Lütfen manuel olarak halledin."
                    exit 1
                fi
            elif [[ -n "$current_mountpoint" ]] && [[ "$current_mountpoint" != " " ]]; then
                echo "$local_part_path, $current_mountpoint adresinden ayrılıyor..."
                if ! sudo umount "$local_part_path"; then
                    echo "Hata: $local_part_path ayrılamadı. Lütfen manuel olarak ayırıp tekrar deneyin."
                    if command -v lsof &> /dev/null; then
                        echo "$local_part_path veya bağlama noktasını kullanan olası işlemler:"
                        lsof "$current_mountpoint"
                        lsof "$local_part_path"
                    fi
                    exit 1
                fi
            fi
        done
        echo "'$disk_name' üzerindeki bölümlerin bağlantısı başarıyla kesildi ve/veya takas alanı devre dışı bırakıldı."
    else
        echo "'$disk_name' üzerinde ayrılacak aktif bağlı bölüm veya takas alanı bulunamadı."
    fi

    if command -v lsof &> /dev/null && lsof "$disk_name" &> /dev/null; then
        echo "Uyarı: 'lsof', '$disk_name' diskinin hala bazı işlemler tarafından kullanılıyor olabileceğini gösteriyor."
        lsof "$disk_name"
        read -p "'lsof' uyarısına rağmen yazma işlemine devam edilsin mi? (yes/NO): " lsof_continue
        if [[ "$lsof_continue" != "yes" ]]; then
            echo "İşlem 'lsof' uyarısı nedeniyle kullanıcı tarafından iptal edildi."
            exit 1
        fi
    fi
fi


echo ""
echo "'$img_path' imaj dosyası '$disk_name' diskine yazılıyor..."
echo "Bu işlem biraz zaman alabilir. Lütfen sabırlı olun."
echo "Blok boyutu: $DD_BLOCK_SIZE"
echo ""

# dd komutunu işletim sistemine göre belirle
DD_CMD_BASE="dd of='$disk_name' bs='$DD_BLOCK_SIZE'"
DD_OFLAGS=""
DD_STATUS_PROGRESS=""

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if [[ "$LINUX_USE_OFLAG_DIRECT" == true ]]; then
        DD_OFLAGS="oflag=direct"
    fi
    DD_STATUS_PROGRESS="status=progress"
    DD_CMD="$DD_CMD_BASE $DD_OFLAGS"
else # macOS veya diğerleri
    DD_CMD="$DD_CMD_BASE"
fi


if [[ "$PV_INSTALLED" == true ]]; then
    echo "'pv' ilerleme takibi için kullanılıyor (Güncelleme aralığı: ${PV_UPDATE_INTERVAL}s)."
    # $img_path ve $disk_name boşluk içerebilirse düzgün çalışması için tırnak içinde olmalı
    # sudo sh -c "..." içindeki değişkenler ($img_size, $img_path, $DD_CMD) geçerli kabuk tarafından genişletilir.
    if ! sudo sh -c "pv -N 'Imaj Yazılıyor' -s \"$img_size\" -petrb -i \"$PV_UPDATE_INTERVAL\" \"$img_path\" | $DD_CMD"; then
        echo "Hata: 'pv | dd' işlemi sırasında hata. Yazma başarısız olmuş veya kesilmiş olabilir."
        exit 1
    fi
else
    echo "Uyarı: 'pv' bulunamadı. İşletim sistemine özgü ilerleme ile 'dd' deneniyor."
    if [[ "$OSTYPE" == "linux-gnu"* ]];
    then
        echo "Linux'ta 'dd $DD_STATUS_PROGRESS' kullanılıyor."
        # $DD_STATUS_PROGRESS'ı if="$img_path" öncesine veya sonrasına eklemek fark etmez
        if ! sudo dd if="$img_path" $DD_CMD $DD_STATUS_PROGRESS; then
             echo "Hata: 'dd' işlemi sırasında hata. Yazma başarısız olmuş veya kesilmiş olabilir."
             exit 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macOS'ta 'pv' olmadan, 'dd' sınırlı geri bildirim sağlar."
        echo "Durumu kontrol etmek için Ctrl+T tuşlarına basmayı (veya başka bir terminalde 'sudo pkill -INFO -x dd' çalıştırmayı) deneyebilirsiniz."
        if ! sudo dd if="$img_path" $DD_CMD; then
             echo "Hata: 'dd' işlemi sırasında hata. Yazma başarısız olmuş veya kesilmiş olabilir."
             exit 1
        fi
    else
        echo "Belirli 'dd' ilerlemesi için desteklenmeyen işletim sistemi. Genel 'dd' deneniyor."
        if ! sudo dd if="$img_path" $DD_CMD; then
             echo "Hata: 'dd' işlemi sırasında hata. Yazma başarısız olmuş veya kesilmiş olabilir."
             exit 1
        fi
    fi
fi

echo "Tüm verilerin diske yazıldığından emin olunuyor (syncing)..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    sync
    sync
else
    sudo sync
fi
sleep 3

echo ""
echo "--------------------------------------------------------------------"
echo "Yazma işlemi '$disk_name' diskine başarıyla tamamlandı."
echo "Şimdi diski güvenle çıkarmayı veya kaldırmayı deneyebilirsiniz."
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macOS'ta, çıkarmak için Disk İzlencesi'ni veya Finder'ı kullanabilirsiniz."
    echo "Komut satırı (isteğe bağlı, uygunsa): diskutil eject $disk_name"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Linux'ta, komut isteminin geri döndüğünden ve sistem etkinliğinin sona erdiğinden emin olun."
    echo "Sync işleminden sonra fiziksel olarak çıkarmak genellikle yeterlidir veya masaüstü ortamınızın çıkarma seçeneğini kullanın."
fi
echo "--------------------------------------------------------------------"

echo ""
echo "--- PERFORMANS İPUÇLARI ---"
echo "Yazma hızı beklentinizden düşükse şunları deneyebilirsiniz:"
echo "1. Blok Boyutu ('bs'): Betiğin başındaki 'DD_BLOCK_SIZE' değişkenini değiştirerek farklı blok boyutları (örn: '1M', '8M', '16M', '32M', '64M', '128M') deneyin. Bazı aygıtlar belirli blok boyutlarında daha hızlı çalışır."
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
echo "2. 'oflag=direct' (Linux): Betiğin başındaki 'LINUX_USE_OFLAG_DIRECT' değişkenini 'false' olarak ayarlayarak işletim sistemi önbelleğini kullanmayı deneyin. Bu, bazı durumlarda hızı artırabilir."
fi
if [[ "$OSTYPE" == "darwin"* ]]; then
echo "3. Raw Disk ('rdisk') (macOS): Eğer betik size '/dev/rdiskX' kullanmayı önermediyse ve siz '/dev/diskX' girdiyseniz, bir sonraki çalıştırmada '/dev/rdiskX' (örn: /dev/rdisk6) deneyin. Bu genellikle daha hızlıdır."
fi
echo "4. USB Bağlantısı: USB 2.0 portu yerine USB 3.0+ portu kullanın. Kaliteli bir USB kablosu ve doğrudan bilgisayar portu (hub yerine) da fark yaratabilir."
echo "5. Sistem Yükü: Yazma işlemi sırasında bilgisayarınızda çalışan diğer yoğun I/O işlemleri hızı etkileyebilir."
echo "6. Hedef Aygıt: Kullandığınız USB bellek, SD kart veya diskin kendi maksimum yazma hızı da bir sınırlayıcı faktördür."
echo "--------------------------"
